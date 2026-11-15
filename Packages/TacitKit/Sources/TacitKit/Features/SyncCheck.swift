import Foundation

/// Measures the offset between face and audio, and between mouth video and audio, from a "pa pa pa" take.
///
/// The audio energy envelope and a mouth signal (`jawOpen`, or how dark the middle of the mouth crop is)
/// are both put on one 100 Hz grid and cross-correlated. The peak is refined with a parabola, so the
/// result resolves well below the 10 ms grid step and below one 40 ms video frame.
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
        let jaw = Constants.blendShapeOrder.firstIndex(of: "jawOpen")!
        let tracked = frames.filter { $0.trackingFlags.contains(.isTracked) }
        return measure(times: tracked.map(\.timestamp), values: tracked.map { Double($0.blendShapes[jaw]) },
                       audio: audio, audioT0: audioT0)
    }

    /// The same check against the mouth video. `pixels[i]` is the crop captured at `times[i]`.
    public static func measureVideo(times: [Double], pixels: [[UInt8]], audio: [Int16], audioT0: Double) -> Result? {
        guard times.count == pixels.count else { return nil }
        return measure(times: times, values: pixels.map { MouthPixels.openness($0) }, audio: audio, audioT0: audioT0)
    }

    /// Correlates any mouth signal sampled at `times` (ascending, iPhone host clock) with the audio.
    public static func measure(times: [Double], values: [Double], audio: [Int16], audioT0: Double) -> Result? {
        guard let first = times.first, let last = times.last, times.count == values.count else { return nil }
        let audioEnd = audioT0 + Double(audio.count) / Constants.audioSampleRate
        let start = max(first, audioT0)
        let count = Int(((min(last, audioEnd) - start) * rate).rounded(.down))
        guard count >= minBins else { return nil }

        let envelope = centered(energyEnvelope(audio, audioT0: audioT0, start: start, count: count))
        let jaw = centered(resample(times: times, values: values, start: start, count: count))
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

    /// The signal linearly interpolated at the centre of each 10 ms bin from `start`.
    static func resample(times: [Double], values: [Double], start: Double, count: Int) -> [Double] {
        var next = 1
        return (0 ..< count).map { bin in
            let time = start + (Double(bin) + 0.5) / rate
            guard times.count > 1 else { return values[0] }
            while next < times.count - 1, times[next] < time { next += 1 }
            let span = times[next] - times[next - 1]
            let weight = span > 0 ? min(max((time - times[next - 1]) / span, 0), 1) : 0
            return values[next - 1] * (1 - weight) + values[next] * weight
        }
    }

    private static func centered(_ values: [Double]) -> [Double] {
        let mean = values.reduce(0, +) / Double(max(values.count, 1))
        return values.map { $0 - mean }
    }
}
