import Foundation

public enum SessionFileError: Error, Equatable {
    case badMagic
    case schemaMismatch(found: UInt16)
    case lipVertexCountMismatch(found: UInt16)
    case lengthMismatch
    case unsupportedWav(String)
}

/// `face.bin`: a 16-byte header, then `FaceFrame` records back to back in the wire layout.
///
/// Header: magic `SFCE`, UInt16 featureSchemaVersion, UInt16 lipVertexCount, UInt32 frameCount,
/// UInt32 reserved. `ml/silentml/constants.py` mirrors it as `FACE_FILE_HEADER_DTYPE`.
public enum FaceFile {
    public static let magic = Array("SFCE".utf8)
    public static let headerSize = 16

    public static func encode(_ frames: [FaceFrame]) throws(ProtocolEncodeError) -> Data {
        guard frames.count <= Int(UInt32.max) else { throw .tooManyFrames }
        var writer = ByteWriter(capacity: headerSize + frames.count * FaceFrame.byteSize)
        writer.write(bytes: magic)
        writer.write(Constants.featureSchemaVersion)
        writer.write(UInt16(Constants.lipVertexCount))
        writer.write(UInt32(frames.count))
        writer.write(UInt32(0))
        for frame in frames { try frame.encode(into: &writer) }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> [FaceFrame] {
        var reader = ByteReader(data)
        guard Array(try reader.readBytes(4)) == magic else { throw SessionFileError.badMagic }
        let schema: UInt16 = try reader.read()
        guard schema == Constants.featureSchemaVersion else { throw SessionFileError.schemaMismatch(found: schema) }
        let lipCount: UInt16 = try reader.read()
        guard Int(lipCount) == Constants.lipVertexCount else { throw SessionFileError.lipVertexCountMismatch(found: lipCount) }
        let count = Int(try reader.read(UInt32.self))
        _ = try reader.read(UInt32.self)
        guard reader.remaining == count * FaceFrame.byteSize else { throw SessionFileError.lengthMismatch }
        var frames: [FaceFrame] = []
        frames.reserveCapacity(count)
        for _ in 0 ..< count { frames.append(try FaceFrame(from: &reader)) }
        return frames
    }
}

/// `audio.wav`: canonical 44-byte RIFF header and 16-bit mono PCM.
public enum WavFile {
    public static func encode(_ samples: [Int16], sampleRate: Int = Int(Constants.audioSampleRate)) -> Data {
        let dataBytes = samples.count * 2
        var writer = ByteWriter(capacity: 44 + dataBytes)
        writer.write(bytes: Array("RIFF".utf8))
        writer.write(UInt32(36 + dataBytes))
        writer.write(bytes: Array("WAVE".utf8))
        writer.write(bytes: Array("fmt ".utf8))
        writer.write(UInt32(16))
        writer.write(UInt16(1)) // PCM
        writer.write(UInt16(1)) // mono
        writer.write(UInt32(sampleRate))
        writer.write(UInt32(sampleRate * 2)) // byte rate
        writer.write(UInt16(2)) // block align
        writer.write(UInt16(16)) // bits per sample
        writer.write(bytes: Array("data".utf8))
        writer.write(UInt32(dataBytes))
        // Apple silicon is little-endian, so the samples are already in file order.
        samples.withUnsafeBytes { writer.write(bytes: $0) }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> (samples: [Int16], sampleRate: Int) {
        var reader = ByteReader(data)
        guard Array(try reader.readBytes(4)) == Array("RIFF".utf8) else { throw SessionFileError.unsupportedWav("not RIFF") }
        _ = try reader.read(UInt32.self)
        guard Array(try reader.readBytes(4)) == Array("WAVE".utf8) else { throw SessionFileError.unsupportedWav("not WAVE") }

        var sampleRate: Int?
        while reader.remaining >= 8 {
            let id = String(decoding: try reader.readBytes(4), as: UTF8.self)
            let size = Int(try reader.read(UInt32.self))
            switch id {
            case "fmt ":
                var fmt = ByteReader(try reader.readBytes(size))
                let format: UInt16 = try fmt.read()
                let channels: UInt16 = try fmt.read()
                let rate: UInt32 = try fmt.read()
                _ = try fmt.read(UInt32.self)
                _ = try fmt.read(UInt16.self)
                let bits: UInt16 = try fmt.read()
                guard format == 1, channels == 1, bits == 16 else {
                    throw SessionFileError.unsupportedWav("expected 16-bit mono PCM")
                }
                sampleRate = Int(rate)
            case "data":
                guard let sampleRate else { throw SessionFileError.unsupportedWav("data before fmt") }
                guard size.isMultiple(of: 2) else { throw SessionFileError.lengthMismatch }
                let bytes = try reader.readBytes(size)
                var samples = [Int16](repeating: 0, count: size / 2)
                _ = samples.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
                return (samples, sampleRate)
            default:
                _ = try reader.readBytes(size + size % 2)
            }
        }
        throw SessionFileError.unsupportedWav("no data chunk")
    }
}
