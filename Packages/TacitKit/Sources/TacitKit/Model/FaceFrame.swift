import Foundation

public struct TrackingFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let isTracked = TrackingFlags(rawValue: 1 << 0)
    public static let trackingNormal = TrackingFlags(rawValue: 1 << 1)
}

/// One ARKit face sample. The binary layout is shared by the wire (`faceBatch`) and `face.bin`.
public struct FaceFrame: Sendable, Equatable {
    /// `ARFrame.timestamp`, host-clock seconds. Same clock as audio PTS.
    public var timestamp: Double
    public var trackingFlags: TrackingFlags
    /// `Constants.blendShapeCount` values in `Constants.blendShapeOrder`.
    public var blendShapes: [Float]
    /// `faceAnchor.transform`, 16 floats, column-major.
    public var headTransform: [Float]
    /// `Constants.lipVertexCount` vertices in face-local coordinates.
    public var lipVertices: [SIMD3<Float>]

    public init(timestamp: Double, trackingFlags: TrackingFlags, blendShapes: [Float],
                headTransform: [Float], lipVertices: [SIMD3<Float>]) {
        self.timestamp = timestamp
        self.trackingFlags = trackingFlags
        self.blendShapes = blendShapes
        self.headTransform = headTransform
        self.lipVertices = lipVertices
    }

    /// A frame with no face. Sent so gaps in tracking are explicit.
    public static func untracked(at timestamp: Double) -> FaceFrame {
        FaceFrame(
            timestamp: timestamp,
            trackingFlags: [],
            blendShapes: Array(repeating: 0, count: Constants.blendShapeCount),
            headTransform: Array(repeating: 0, count: 16),
            lipVertices: Array(repeating: .zero, count: Constants.lipVertexCount)
        )
    }

    /// 1,052 bytes with 64 lip vertices.
    public static let byteSize = 8 + 4 + Constants.blendShapeCount * 4 + 16 * 4 + Constants.lipVertexCount * 3 * 4

    func encode(into writer: inout ByteWriter) throws(ProtocolEncodeError) {
        guard blendShapes.count == Constants.blendShapeCount,
              headTransform.count == 16,
              lipVertices.count == Constants.lipVertexCount
        else { throw .invalidFaceFrame }

        writer.write(timestamp)
        writer.write(trackingFlags.rawValue)
        for value in blendShapes { writer.write(value) }
        for value in headTransform { writer.write(value) }
        for vertex in lipVertices {
            writer.write(vertex.x)
            writer.write(vertex.y)
            writer.write(vertex.z)
        }
    }

    init(from reader: inout ByteReader) throws(ProtocolDecodeError) {
        timestamp = try reader.read()
        trackingFlags = TrackingFlags(rawValue: try reader.read())
        blendShapes = []
        blendShapes.reserveCapacity(Constants.blendShapeCount)
        for _ in 0 ..< Constants.blendShapeCount { blendShapes.append(try reader.read()) }
        headTransform = []
        headTransform.reserveCapacity(16)
        for _ in 0 ..< 16 { headTransform.append(try reader.read()) }
        lipVertices = []
        lipVertices.reserveCapacity(Constants.lipVertexCount)
        for _ in 0 ..< Constants.lipVertexCount {
            lipVertices.append(SIMD3(try reader.read(), try reader.read(), try reader.read()))
        }
    }
}

/// `faceBatch` payload: UInt16 frame count followed by frames back to back.
public struct FaceBatch: Sendable, Equatable {
    public var frames: [FaceFrame]

    public init(frames: [FaceFrame]) {
        self.frames = frames
    }

    func encoded() throws(ProtocolEncodeError) -> Data {
        guard frames.count <= Int(UInt16.max) else { throw .tooManyFrames }
        var writer = ByteWriter(capacity: 2 + frames.count * FaceFrame.byteSize)
        writer.write(UInt16(frames.count))
        for frame in frames { try frame.encode(into: &writer) }
        return writer.data
    }

    init(decoding data: Data) throws(ProtocolDecodeError) {
        var reader = ByteReader(data)
        let count = Int(try reader.read(UInt16.self))
        guard reader.remaining == count * FaceFrame.byteSize else { throw .lengthMismatch }
        frames = []
        frames.reserveCapacity(count)
        for _ in 0 ..< count { frames.append(try FaceFrame(from: &reader)) }
    }
}
