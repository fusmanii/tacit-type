import Foundation

/// How much the mouth is moving, frame by frame. Drives the mouth-activity gate (Step 2) and the
/// silent dictation trim (Step 3).
///
/// The score is the L2 norm of the frame-to-frame velocity of the 29 `MouthBlendShapes`, in blendshape
/// units per second, smoothed with a 100 ms moving average. Raw values, not z-scored.
public enum MouthActivity {
    public static let smoothingWindow = 0.1
    /// Used until the user has recorded "stay still" takes. Tuned in M4: ARKit jitter on a still
    /// face scores about 0.2 … 0.4, and speech scores 2 … 8.
    public static let defaultThreshold = 1.0
    /// θ = mean + `thresholdSigmas` × std of the score over the neutral takes.
    public static let thresholdSigmas = 4.0

    public struct Track: Sendable, Equatable {
        /// iPhone host-clock seconds, one per face frame.
        public var times: [Double]
        public var scores: [Double]
        public var tracked: [Bool]

        public var trackedRatio: Double {
            tracked.isEmpty ? 0 : Double(tracked.count { $0 }) / Double(tracked.count)
        }
    }

    /// One score per frame. Untracked frames score 0. The first frame after a gap has no velocity of its own.
    public static func track(_ frames: [FaceFrame]) -> Track {
        let indices = MouthBlendShapes.wireIndices
        var raw = [Double](repeating: 0, count: frames.count)
        let tracked = frames.map { $0.trackingFlags.contains(.isTracked) }
        for i in frames.indices.dropFirst() where tracked[i] && tracked[i - 1] {
            let dt = frames[i].timestamp - frames[i - 1].timestamp
            guard dt > 0 else { continue }
            var sum = 0.0
            for index in indices {
                let velocity = Double(frames[i].blendShapes[index] - frames[i - 1].blendShapes[index]) / dt
                sum += velocity * velocity
            }
            raw[i] = sum.squareRoot()
        }

        // Trailing moving average over the frames inside the window, so a score only uses the past.
        var smoothed = [Double](repeating: 0, count: frames.count)
        var start = 0
        var sum = 0.0
        for i in frames.indices {
            sum += raw[i]
            while frames[i].timestamp - frames[start].timestamp >= smoothingWindow - 1e-9 {
                sum -= raw[start]
                start += 1
            }
            smoothed[i] = sum / Double(i - start + 1)
        }
        for i in frames.indices where !tracked[i] { smoothed[i] = 0 }
        return Track(times: frames.map(\.timestamp), scores: smoothed, tracked: tracked)
    }

    /// θ from the user's "stay still" takes. Nil when they hold no tracked frames.
    public static func threshold(neutral takes: [[FaceFrame]]) -> Double? {
        let scores = takes.flatMap { frames in
            let track = track(frames)
            return zip(track.scores, track.tracked).filter(\.1).map(\.0)
        }
        guard scores.count > 1 else { return nil }
        let mean = scores.reduce(0, +) / Double(scores.count)
        let variance = scores.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(scores.count)
        return mean + thresholdSigmas * variance.squareRoot()
    }
}

/// Lets audio through only while the mouth is moving. See "Mouth-activity gate" in docs/SPEC.md.
public enum MouthGate {
    public static let openAfter = 0.08
    public static let closeRatio = 0.6
    public static let closeAfter = 0.3
    public static let mergeGap = 0.4
    public static let padBefore = 0.15
    public static let padAfter = 0.25
    /// Closed stretches longer than this inside the kept clip are zeroed.
    public static let zeroGapsLongerThan = 0.6
    /// Below this tracked ratio the gate steps aside and the energy VAD decides alone.
    public static let minTrackedRatio = 0.8
    /// Mouth open but the VAD fires on fewer than this share of the open audio frames: mouthed silently.
    public static let minVoicedRatio = 0.2
    /// A region whose raw start is this close to the first tracked frame began before the camera did.
    public static let leadingMotionWindow = 0.1
    /// Used by silent dictation (Step 3): above this share, the user spoke out loud.
    public static let spokenRatio = 0.5

    public struct Region: Sendable, Equatable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }

        public var duration: Double { end - start }
    }

    public enum Decision: Sendable, Equatable {
        /// The mouth never moved.
        case noActivity
        /// The mouth moved but almost nothing was heard.
        case silentMouthing
        /// Send this audio to Whisper. Same length as the input, with everything outside the regions zeroed
        /// and the ends trimmed, so `startSample` maps it back onto the clip.
        case speech(audio: [Int16], startSample: Int)
    }

    public struct Result: Sendable, Equatable {
        public var decision: Decision
        /// Padded, merged open regions, host-clock seconds. Empty when bypassed.
        public var regions: [Region]
        /// True when tracking was too poor and the energy VAD decided alone.
        public var bypassed: Bool
        /// Share of 20 ms audio frames inside the regions that the VAD calls speech.
        public var voicedRatio: Double
        /// Seconds of the clip that the gate trimmed or zeroed.
        public var gatedOutSeconds: Double
    }

    /// Open regions before padding and merging, from the hysteresis rule alone.
    public static func rawRegions(_ track: MouthActivity.Track, threshold: Double) -> [Region] {
        var regions: [Region] = []
        var isOpen = false
        var runStart: Double?
        var openedAt = 0.0
        for (i, time) in track.times.enumerated() {
            let score = track.tracked[i] ? track.scores[i] : 0
            if !isOpen {
                if score > threshold {
                    let start = runStart ?? time
                    runStart = start
                    if time - start >= openAfter - 1e-9 {
                        isOpen = true
                        openedAt = start
                        runStart = nil
                    }
                } else {
                    runStart = nil
                }
            } else {
                if score < closeRatio * threshold {
                    let start = runStart ?? time
                    runStart = start
                    if time - start >= closeAfter - 1e-9 {
                        isOpen = false
                        regions.append(Region(start: openedAt, end: start))
                        runStart = nil
                    }
                } else {
                    runStart = nil
                }
            }
        }
        if isOpen, let last = track.times.last { regions.append(Region(start: openedAt, end: runStart ?? last)) }
        return regions
    }

    /// Merges regions less than `mergeGap` apart, then pads each one.
    public static func regions(_ track: MouthActivity.Track, threshold: Double) -> [Region] {
        var merged: [Region] = []
        for region in rawRegions(track, threshold: threshold) {
            if let last = merged.last, region.start - last.end < mergeGap {
                merged[merged.count - 1].end = region.end
            } else {
                merged.append(region)
            }
        }
        var padded: [Region] = []
        for region in merged {
            let next = Region(start: region.start - padBefore, end: region.end + padAfter)
            if let last = padded.last, next.start <= last.end {
                padded[padded.count - 1].end = next.end
            } else {
                padded.append(next)
            }
        }
        return padded
    }

    /// Runs the whole gate on one clip.
    public static func apply(frames: [FaceFrame], audio: [Int16], audioT0: Double,
                             threshold: Double = MouthActivity.defaultThreshold) -> Result {
        let track = MouthActivity.track(frames)
        let levels = AudioLevel.frameLevels(audio)
        let speech = AudioLevel.speechFrames(levels)
        let rate = Constants.audioSampleRate

        guard track.trackedRatio >= minTrackedRatio else {
            let voiced = AudioLevel.speechDuration(audio)
            let decision: Decision = voiced < TakeQuality.minSpeech ? .noActivity : .speech(audio: audio, startSample: 0)
            return Result(decision: decision, regions: [], bypassed: true,
                          voicedRatio: speech.isEmpty ? 0 : Double(speech.count { $0 }) / Double(speech.count),
                          gatedOutSeconds: 0)
        }

        var regions = regions(track, threshold: threshold)
        // Audio starts before the TrueDepth camera does (about 420 ms). If the mouth was already moving
        // in the first tracked frames, the user started speaking before the face could be seen, so the
        // first region reaches back to the start of the audio.
        if let first = regions.first, let firstTracked = zip(track.times, track.tracked).first(where: \.1)?.0,
           first.start + padBefore - firstTracked < leadingMotionWindow {
            regions[0].start = min(first.start, audioT0)
        }
        guard !regions.isEmpty else {
            return Result(decision: .noActivity, regions: [], bypassed: false, voicedRatio: 0,
                          gatedOutSeconds: Double(audio.count) / rate)
        }

        func sample(_ time: Double) -> Int { min(max(Int(((time - audioT0) * rate).rounded()), 0), audio.count) }

        var openFrames = 0
        var voicedFrames = 0
        for (index, isSpeech) in speech.enumerated() {
            let time = audioT0 + (Double(index) + 0.5) * AudioLevel.frameDuration
            if regions.contains(where: { $0.start <= time && time < $0.end }) {
                openFrames += 1
                if isSpeech { voicedFrames += 1 }
            }
        }
        let voicedRatio = openFrames == 0 ? 0 : Double(voicedFrames) / Double(openFrames)

        let first = sample(regions[0].start)
        let last = sample(regions[regions.count - 1].end)
        guard openFrames > 0, voicedRatio >= minVoicedRatio, last > first else {
            return Result(decision: openFrames == 0 ? .noActivity : .silentMouthing, regions: regions, bypassed: false,
                          voicedRatio: voicedRatio, gatedOutSeconds: Double(audio.count) / rate)
        }

        var gated = Array(audio[first ..< last])
        var zeroed = 0
        for (a, b) in zip(regions, regions.dropFirst()) where b.start - a.end > zeroGapsLongerThan {
            let from = sample(a.end) - first
            let to = sample(b.start) - first
            for i in from ..< to { gated[i] = 0 }
            zeroed += to - from
        }
        let removed = audio.count - gated.count + zeroed
        return Result(decision: .speech(audio: gated, startSample: first), regions: regions, bypassed: false,
                      voicedRatio: voicedRatio, gatedOutSeconds: Double(removed) / rate)
    }
}
