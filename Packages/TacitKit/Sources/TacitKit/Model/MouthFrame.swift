import Foundation

/// One grayscale mouth crop as it travels in `mouthBatch`.
///
/// Layout: Float64 timestamp, UInt8 landmarkCount, landmarkCount × (Float32 x, Float32 y) in crop pixels,
/// UInt32 jpegLength, JPEG bytes (192×192 grayscale).
public struct MouthFrame: Sendable, Equatable {
    /// `ARFrame.timestamp` of the frame the crop came from. Same host clock as face frames and audio.
    public var timestamp: Double
    /// `CropLandmark` slots mapped into crop pixels. Points may lie outside the crop (the eyes often do).
    public var landmarks: [SIMD2<Float>]
    public var jpeg: Data

    public init(timestamp: Double, landmarks: [SIMD2<Float>], jpeg: Data) {
        self.timestamp = timestamp
        self.landmarks = landmarks
        self.jpeg = jpeg
    }

    func encode(into writer: inout ByteWriter) throws(ProtocolEncodeError) {
        guard landmarks.count <= Int(UInt8.max), jpeg.count <= Int(UInt32.max) else { throw .invalidMouthFrame }
        writer.write(timestamp)
        writer.write(UInt8(landmarks.count))
        for point in landmarks {
            writer.write(point.x)
            writer.write(point.y)
        }
        writer.write(UInt32(jpeg.count))
        writer.write(bytes: jpeg)
    }

    init(from reader: inout ByteReader) throws(ProtocolDecodeError) {
        timestamp = try reader.read()
        let count = Int(try reader.read(UInt8.self))
        landmarks = []
        landmarks.reserveCapacity(count)
        for _ in 0 ..< count { landmarks.append(SIMD2(try reader.read(), try reader.read())) }
        let length = Int(try reader.read(UInt32.self))
        jpeg = try reader.readBytes(length)
    }
}

/// `mouthBatch` payload: UInt16 frame count followed by frames back to back.
public struct MouthBatch: Sendable, Equatable {
    public var frames: [MouthFrame]

    public init(frames: [MouthFrame]) {
        self.frames = frames
    }

    func encoded() throws(ProtocolEncodeError) -> Data {
        guard frames.count <= Int(UInt16.max) else { throw .tooManyFrames }
        var writer = ByteWriter(capacity: 2 + frames.reduce(0) { $0 + 17 + $1.landmarks.count * 8 + $1.jpeg.count })
        writer.write(UInt16(frames.count))
        for frame in frames { try frame.encode(into: &writer) }
        return writer.data
    }

    init(decoding data: Data) throws(ProtocolDecodeError) {
        var reader = ByteReader(data)
        let count = Int(try reader.read(UInt16.self))
        frames = []
        frames.reserveCapacity(count)
        for _ in 0 ..< count { frames.append(try MouthFrame(from: &reader)) }
        guard reader.remaining == 0 else { throw .lengthMismatch }
    }
}

/// Groups mouth frames into `mouthBatch` messages on the iPhone, one batch per `interval` of frame time.
public struct MouthBatcher: Sendable {
    public let interval: Double
    private var frames: [MouthFrame] = []

    public init(interval: Double = Constants.mouthBatchInterval) {
        self.interval = interval
    }

    public var isEmpty: Bool { frames.isEmpty }

    /// Adds a frame. Returns the previous batch when this frame falls outside its window.
    public mutating func append(_ frame: MouthFrame) -> MouthBatch? {
        var due: MouthBatch?
        if let first = frames.first, frame.timestamp - first.timestamp >= interval - 1e-6 {
            due = flush()
        }
        frames.append(frame)
        return due
    }

    public mutating func flush() -> MouthBatch? {
        guard !frames.isEmpty else { return nil }
        defer { frames.removeAll(keepingCapacity: true) }
        return MouthBatch(frames: frames)
    }
}

/// Picks 25 fps out of ARKit's 60 fps: for each 40 ms tick, the frame nearest the tick.
///
/// A frame is kept when it is the first one within half a frame period of the next tick. The period
/// is the last gap between frames, so this works at any camera rate. After a dropout (a gap over
/// 100 ms) the ticks it covered are skipped rather than bunched, and sampling picks up on the grid.
public struct MouthFrameSampler: Sendable {
    public let tickInterval: Double
    private var nextTick: Double?
    private var lastTimestamp: Double?

    public init(fps: Double = Constants.mouthFps) {
        tickInterval = 1 / fps
    }

    /// True when the frame at `timestamp` should become a mouth frame.
    public mutating func shouldKeep(_ timestamp: Double) -> Bool {
        defer { lastTimestamp = timestamp }
        guard let tick = nextTick else {
            nextTick = timestamp + tickInterval
            return true
        }
        let gap = lastTimestamp.map { timestamp - $0 } ?? 0
        let period = gap > 0 && gap < 0.1 ? gap : 1.0 / 60
        guard timestamp >= tick - period / 2 else { return false }
        var next = tick + tickInterval
        while next <= timestamp + period / 2 { next += tickInterval }
        nextTick = next
        return true
    }
}
