@preconcurrency import AVFoundation
import CoreVideo
import Foundation

/// `mouth.bin`: the exact capture time and crop landmarks of each frame in `mouth.mp4`.
///
/// Header (12 bytes): magic `SMTH`, UInt16 version, UInt16 landmarkCount, UInt32 frameCount.
/// Then per frame: Float64 timestamp, landmarkCount × (Float32 x, Float32 y) in crop pixels.
/// `ml/silentml/constants.py` mirrors it as `MOUTH_FILE_HEADER_DTYPE` and `mouth_record_dtype`.
public enum MouthFile {
    public static let magic = Array("SMTH".utf8)
    public static let headerSize = 12

    public struct Record: Sendable, Equatable {
        public var timestamp: Double
        public var landmarks: [SIMD2<Float>]

        public init(timestamp: Double, landmarks: [SIMD2<Float>]) {
            self.timestamp = timestamp
            self.landmarks = landmarks
        }
    }

    public static func recordSize(landmarkCount: Int) -> Int { 8 + landmarkCount * 8 }

    public static func encode(_ frames: [MouthFrame]) throws(ProtocolEncodeError) -> Data {
        let count = frames.first?.landmarks.count ?? Constants.cropLandmarkCount
        guard frames.count <= Int(UInt32.max), count <= Int(UInt16.max),
              frames.allSatisfy({ $0.landmarks.count == count })
        else { throw .invalidMouthFrame }
        var writer = ByteWriter(capacity: headerSize + frames.count * recordSize(landmarkCount: count))
        writer.write(bytes: magic)
        writer.write(Constants.mouthFileVersion)
        writer.write(UInt16(count))
        writer.write(UInt32(frames.count))
        for frame in frames {
            writer.write(frame.timestamp)
            for point in frame.landmarks {
                writer.write(point.x)
                writer.write(point.y)
            }
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> [Record] {
        var reader = ByteReader(data)
        guard Array(try reader.readBytes(4)) == magic else { throw SessionFileError.badMagic }
        let version: UInt16 = try reader.read()
        guard version == Constants.mouthFileVersion else { throw SessionFileError.mouthVersionMismatch(found: version) }
        let landmarkCount = Int(try reader.read(UInt16.self))
        let count = Int(try reader.read(UInt32.self))
        guard reader.remaining == count * recordSize(landmarkCount: landmarkCount) else { throw SessionFileError.lengthMismatch }
        var records: [Record] = []
        records.reserveCapacity(count)
        for _ in 0 ..< count {
            let timestamp: Double = try reader.read()
            var landmarks: [SIMD2<Float>] = []
            landmarks.reserveCapacity(landmarkCount)
            for _ in 0 ..< landmarkCount { landmarks.append(SIMD2(try reader.read(), try reader.read())) }
            records.append(Record(timestamp: timestamp, landmarks: landmarks))
        }
        return records
    }
}

/// `mouth.mp4`: the mouth crops as H.264 at a constant 25 fps, frame `i` at `i / 25` s.
/// The real capture time of each frame is in `mouth.bin`.
///
/// Written in video range (luma 16 … 235), which every player and ffmpeg read the same way.
/// `read` and `ml/silentml/data.py` expand it back to 0 … 255.
public enum MouthVideo {
    public enum VideoError: Error, Equatable {
        case cannotWrite(String)
        case cannotRead(String)
    }

    /// High enough that the encoder adds little on top of the iPhone's JPEG.
    public static let bitRate = 2_000_000

    public static func write(_ frames: [[UInt8]], to url: URL, size: Int = Constants.mouthCropSize,
                             fps: Double = Constants.mouthFps) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(fps),
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
        ])
        guard writer.canAdd(input) else { throw VideoError.cannotWrite("can't add a video input") }
        writer.add(input)
        guard writer.startWriting() else { throw VideoError.cannotWrite(String(describing: writer.error)) }
        writer.startSession(atSourceTime: .zero)

        let timescale = CMTimeScale(fps.rounded())
        for (index, pixels) in frames.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else { throw VideoError.cannotWrite("no pixel buffer pool") }
            let buffer = try makeBuffer(pixels, size: size, pool: pool)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: timescale)) else {
                throw VideoError.cannotWrite(String(describing: writer.error))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw VideoError.cannotWrite(String(describing: writer.error)) }
    }

    /// Decodes every frame back to `size × size` gray pixels, 0 … 255.
    public static func read(_ url: URL, size: Int = Constants.mouthCropSize) async throws -> [[UInt8]] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.cannotRead("no video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        guard reader.startReading() else { throw VideoError.cannotRead(String(describing: reader.error)) }
        var frames: [[UInt8]] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append(try lumaPixels(buffer, size: size))
        }
        guard reader.status == .completed else { throw VideoError.cannotRead(String(describing: reader.error)) }
        return frames
    }

    /// Full range 0 … 255 → video range 16 … 235.
    static func toVideoRange(_ value: UInt8) -> UInt8 { UInt8((Int(value) * 219 + 127) / 255 + 16) }

    /// Video range → full range, clamped.
    static func toFullRange(_ value: UInt8) -> UInt8 {
        UInt8(clamping: ((Int(value) - 16) * 255 + 109) / 219)
    }

    private static func makeBuffer(_ pixels: [UInt8], size: Int, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let buffer = made, pixels.count == size * size else { throw VideoError.cannotWrite("bad frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        for row in 0 ..< size {
            for column in 0 ..< size { luma[row * lumaRow + column] = toVideoRange(pixels[row * size + column]) }
        }
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        memset(chroma, 128, chromaRow * CVPixelBufferGetHeightOfPlane(buffer, 1))
        return buffer
    }

    private static func lumaPixels(_ buffer: CVPixelBuffer, size: Int) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetWidthOfPlane(buffer, 0) == size, CVPixelBufferGetHeightOfPlane(buffer, 0) == size,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        else { throw VideoError.cannotRead("unexpected frame size") }
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: size * size)
        for y in 0 ..< size {
            for x in 0 ..< size { pixels[y * size + x] = toFullRange(luma[y * row + x]) }
        }
        return pixels
    }
}
