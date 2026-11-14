import Foundation

/// Measures the offset between face and audio from a "pa pa pa" take.
///
/// The audio energy envelope and `jawOpen` are both put on one 100 Hz grid and cross-correlated.
/// The peak is refined with a parabola, so the result resolves well below the 10 ms grid step.
public enum SyncCheck {
    public struct Result: Sendable, Equatable {
        /// Positive when the sound arrives later than the matching jaw movement.
        public var lagMs: Double
        /// Normalised correlation at the peak, 0 … 1.
        public var correlation: Double

        public var passed: Bool { abs(lagMs) < SyncCheck.maxLagMs }
    }

    public static let maxLagMs = 20.0
    static let rate = 100.0
    static let searchBins = 20
    static let minCorrelation = 0.3
    static let minBins = 100

    /// Nil when the take is under a second long or the two signals don't line up anywhere.
    public static func measure(frames: [FaceFrame], audio: [Int16], audioT0: Double) -> Result? {
        let tracked = frames.filter { $0.trackingFlags.contains(.isTracked) }
        guard let first = tracked.first, let last = tracked.last else { return nil }
        let audioEnd = audioT0 + Double(audio.count) / Constants.audioSampleRate
        let start = max(first.timestamp, audioT0)
        let count = Int(((min(last.timestamp, audioEnd) - start) * rate).rounded(.down))
        guard count >= minBins else { return nil }

        let envelope = centered(energyEnvelope(audio, audioT0: audioT0, start: start, count: count))
        let jaw = centered(jawOpen(tracked, start: start, count: count))
        let scale = (envelope.reduce(0) { $0 + $1 * $1 } * jaw.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard scale > 0 else { return nil }

        let lags = Array(-searchBins ... searchBins)
        let scores = lags.map { lag in
            var sum = 0.0
            for i in max(0, -lag) ..< min(count, count - lag) { sum += envelope[i + lag] * jaw[i] }
            return sum / scale
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] >= minCorrelation else { return nil }

        var peak = Double(lags[best])
        if best > 0, best < scores.count - 1 {
            let (a, b, c) = (scores[best - 1], scores[best], scores[best + 1])
            let curvature = a - 2 * b + c
            if curvature < 0 { peak += 0.5 * (a - c) / curvature }
        }
        return Result(lagMs: peak * 1000 / rate, correlation: scores[best])
    }

    /// RMS of the audio in each 10 ms bin from `start`.
    static func energyEnvelope(_ audio: [Int16], audioT0: Double, start: Double, count: Int) -> [Double] {
        let perBin = Constants.audioSampleRate / rate
        let offset = (start - audioT0) * Constants.audioSampleRate
        return (0 ..< count).map { bin in
            let from = max(0, Int((offset + Double(bin) * perBin).rounded()))
            let to = min(audio.count, Int((offset + Double(bin + 1) * perBin).rounded()))
            guard to > from else { return 0 }
            var sum = 0.0
            for sample in audio[from ..< to] {
                let value = Double(sample) / 32_768
                sum += value * value
            }
            return (sum / Double(to - from)).squareRoot()
        }
    }

    /// `jawOpen` linearly interpolated at the centre of each 10 ms bin from `start`.
    static func jawOpen(_ frames: [FaceFrame], start: Double, count: Int) -> [Double] {
        let channel = Constants.blendShapeOrder.firstIndex(of: "jawOpen")!
        var next = 1
        return (0 ..< count).map { bin in
            let time = start + (Double(bin) + 0.5) / rate
            while next < frames.count - 1, frames[next].timestamp < time { next += 1 }
            guard frames.count > 1 else { return Double(frames[0].blendShapes[channel]) }
            let (a, b) = (frames[next - 1], frames[next])
            let span = b.timestamp - a.timestamp
            let weight = span > 0 ? min(max((time - a.timestamp) / span, 0), 1) : 0
            return Double(a.blendShapes[channel]) * (1 - weight) + Double(b.blendShapes[channel]) * weight
        }
    }

    private static func centered(_ values: [Double]) -> [Double] {
        let mean = values.reduce(0, +) / Double(max(values.count, 1))
        return values.map { $0 - mean }
    }
}
