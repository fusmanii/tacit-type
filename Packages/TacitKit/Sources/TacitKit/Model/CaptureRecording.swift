import Foundation

/// Quality numbers for one capture, as they go into `manifest.json`.
public struct CaptureMetrics: Sendable, Equatable {
    public var frameCount = 0
    public var trackedFrameCount = 0
    /// `(frameCount − 1) / (last − first timestamp)`.
    public var measuredFps: Double = 0
    public var trackedRatio: Double = 0
    /// Expected frames minus received frames, from the gaps between timestamps.
    public var droppedFrames = 0
    public var audioGapsFilled = 0
    public var audioSampleCount = 0
    public var firstFaceTs: Double?
    public var firstTrackedFaceTs: Double?
    public var firstAudioTs: Double?
    public var mouthFrameCount = 0
    public var mouthFps: Double = 0
    /// Mouth frames that should have arrived over the face frames' time span, at 25 fps.
    public var expectedMouthFrames = 0
    public var meanLuma: Double?

    public init() {}

    public var faceDuration: Double {
        guard frameCount > 1, measuredFps > 0 else { return 0 }
        return Double(frameCount - 1) / measuredFps
    }

    public var audioDuration: Double { Double(audioSampleCount) / Constants.audioSampleRate }

    /// Dropped frames as a share of the frames that should have arrived.
    public var droppedRatio: Double {
        let expected = frameCount + droppedFrames
        return expected > 0 ? Double(droppedFrames) / Double(expected) : 0
    }

    /// Mouth frames received as a share of those expected. 1 when none were expected.
    public var mouthReceivedRatio: Double {
        expectedMouthFrames > 0 ? min(1, Double(mouthFrameCount) / Double(expectedMouthFrames)) : 1
    }
}

/// Collects one session's face frames and audio on the Mac, in arrival order.
///
/// Audio is laid out so sample index ↔ time stays linear from `audioT0`. A PTS jump of more than
/// `audioGapTolerance` is filled with zeros and counted. Overlapping samples are dropped.
public struct CaptureRecording: Sendable {
    public static let audioGapTolerance = 0.001

    public let sessionId: UUID
    public private(set) var frames: [FaceFrame] = []
    public private(set) var audio: [Int16] = []
    /// PTS of `audio[0]`, iPhone host clock.
    public private(set) var audioT0: Double?
    public private(set) var audioGapsFilled = 0
    public private(set) var mouthFrames: [MouthFrame] = []
    /// Mean luma of each mouth frame, decoded on arrival. NaN where the JPEG didn't decode.
    public private(set) var mouthLuma: [Float] = []

    public init(sessionId: UUID) {
        self.sessionId = sessionId
    }

    public mutating func append(_ batch: FaceBatch) {
        frames.append(contentsOf: batch.frames)
    }

    public mutating func append(_ batch: MouthBatch) {
        for frame in batch.frames {
            mouthFrames.append(frame)
            mouthLuma.append((try? MouthJPEG.decode(frame.jpeg)).map(MouthPixels.meanLuma) ?? .nan)
        }
    }

    /// Decoded mouth crops, in frame order. Frames whose JPEG doesn't decode come back black.
    public func mouthPixels() -> [[UInt8]] {
        let blank = [UInt8](repeating: 0, count: Constants.mouthCropSize * Constants.mouthCropSize)
        return mouthFrames.map { (try? MouthJPEG.decode($0.jpeg)) ?? blank }
    }

    public mutating func append(_ chunk: AudioChunk) {
        guard let t0 = audioT0 else {
            audioT0 = chunk.ptsOfFirstSample
            audio.append(contentsOf: chunk.samples)
            return
        }
        let expected = t0 + Double(audio.count) / Constants.audioSampleRate
        let jump = chunk.ptsOfFirstSample - expected
        if jump > Self.audioGapTolerance {
            audio.append(contentsOf: repeatElement(0, count: Int((jump * Constants.audioSampleRate).rounded())))
            audioGapsFilled += 1
            audio.append(contentsOf: chunk.samples)
        } else if jump < -Self.audioGapTolerance {
            let overlap = Int((-jump * Constants.audioSampleRate).rounded())
            audio.append(contentsOf: chunk.samples.dropFirst(overlap))
        } else {
            audio.append(contentsOf: chunk.samples)
        }
    }

    public var metrics: CaptureMetrics {
        var metrics = CaptureMetrics()
        metrics.frameCount = frames.count
        metrics.trackedFrameCount = frames.lazy.filter { $0.trackingFlags.contains(.isTracked) }.count
        metrics.trackedRatio = frames.isEmpty ? 0 : Double(metrics.trackedFrameCount) / Double(frames.count)
        metrics.firstFaceTs = frames.first?.timestamp
        metrics.firstTrackedFaceTs = frames.first { $0.trackingFlags.contains(.isTracked) }?.timestamp
        metrics.firstAudioTs = audioT0
        metrics.audioSampleCount = audio.count
        metrics.audioGapsFilled = audioGapsFilled
        if let first = frames.first, let last = frames.last, last.timestamp > first.timestamp {
            metrics.measuredFps = Double(frames.count - 1) / (last.timestamp - first.timestamp)
        }
        metrics.droppedFrames = Self.droppedFrames(in: frames.map(\.timestamp))

        metrics.mouthFrameCount = mouthFrames.count
        if let first = mouthFrames.first, let last = mouthFrames.last, last.timestamp > first.timestamp {
            metrics.mouthFps = Double(mouthFrames.count - 1) / (last.timestamp - first.timestamp)
        }
        if let first = frames.first, let last = frames.last {
            metrics.expectedMouthFrames = Int(((last.timestamp - first.timestamp) * Constants.mouthFps + 1e-6).rounded(.down)) + 1
        }
        let luma = mouthLuma.filter { !$0.isNaN }
        if !luma.isEmpty { metrics.meanLuma = Double(luma.reduce(0, +)) / Double(luma.count) }
        return metrics
    }

    /// Expected frames minus received frames. The nominal period is the median of 4-frame spans
    /// divided by 4, which shrugs off both per-frame jitter and the odd drop.
    static func droppedFrames(in timestamps: [Double]) -> Int {
        let step = 4
        guard timestamps.count > step + 1, let first = timestamps.first, let last = timestamps.last else { return 0 }
        let spans = zip(timestamps.dropFirst(step), timestamps).map { ($0 - $1) / Double(step) }.sorted()
        let period = spans[spans.count / 2]
        guard period > 0 else { return 0 }
        let expected = Int(((last - first) / period).rounded()) + 1
        return max(0, expected - timestamps.count)
    }
}
