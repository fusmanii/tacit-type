import Foundation

/// `audioChunk` payload: Float64 PTS of the first sample, then Int16 PCM at 16 kHz mono.
public struct AudioChunk: Sendable, Equatable {
    /// Host-clock seconds, same clock as `FaceFrame.timestamp`.
    public var ptsOfFirstSample: Double
    public var samples: [Int16]

    public init(ptsOfFirstSample: Double, samples: [Int16]) {
        self.ptsOfFirstSample = ptsOfFirstSample
        self.samples = samples
    }

    public var duration: Double { Double(samples.count) / Constants.audioSampleRate }

    func encoded() -> Data {
        var writer = ByteWriter(capacity: 8 + samples.count * 2)
        writer.write(ptsOfFirstSample)
        for sample in samples { writer.write(sample) }
        return writer.data
    }

    init(decoding data: Data) throws(ProtocolDecodeError) {
        var reader = ByteReader(data)
        ptsOfFirstSample = try reader.read()
        guard reader.remaining.isMultiple(of: 2) else { throw .lengthMismatch }
        let count = reader.remaining / 2
        samples = []
        samples.reserveCapacity(count)
        for _ in 0 ..< count { samples.append(try reader.read()) }
    }
}
