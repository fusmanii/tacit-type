import Foundation

/// Audio loudness in 20 ms frames, and the simple energy VAD built on it.
public enum AudioLevel {
    public static let frameDuration = 0.02
    static let frameLength = Int(Constants.audioSampleRate * frameDuration)
    /// Level reported for digital silence.
    public static let floorDb = -120.0

    /// RMS of each full 20 ms frame, in dBFS.
    public static func frameLevels(_ samples: [Int16]) -> [Double] {
        stride(from: 0, to: samples.count - frameLength + 1, by: frameLength).map { start in
            var sum = 0.0
            for sample in samples[start ..< start + frameLength] {
                let value = Double(sample) / 32_768
                sum += value * value
            }
            let rms = (sum / Double(frameLength)).squareRoot()
            return rms > 0 ? max(20 * log10(rms), floorDb) : floorDb
        }
    }

    /// Frames that stand 9 dB above the clip's noise floor (its 10th percentile).
    /// The threshold is clamped to −55 … −30 dBFS, so hiss never counts and loud speech always does.
    public static func speechFrames(_ levels: [Double]) -> [Bool] {
        guard !levels.isEmpty else { return [] }
        let noiseFloor = levels.sorted()[levels.count / 10]
        let threshold = min(max(noiseFloor + 9, -55), -30)
        return levels.map { $0 > threshold }
    }

    /// Seconds of audio the VAD calls speech.
    public static func speechDuration(_ samples: [Int16]) -> Double {
        Double(speechFrames(frameLevels(samples)).count { $0 }) * frameDuration
    }

    /// Seconds of audio louder than `db` dBFS.
    public static func duration(above db: Double, in samples: [Int16]) -> Double {
        Double(frameLevels(samples).count { $0 > db }) * frameDuration
    }
}

/// The Recorder's per-take checks. Flagged takes are saved with `quality.ok = false`.
public enum TakeQuality {
    public enum Flag: String, Sendable, CaseIterable {
        case poorTracking = "poor_tracking"
        case noSpeech = "no_speech"
        case audibleInSilent = "audible_in_silent"
        case tooShort = "too_short"
        case tooLong = "too_long"
        /// Sync check only: face and audio are 20 ms or more apart.
        case syncOffset = "sync_offset"
        /// Sync check only: no clear correlation between the jaw and the sound.
        case syncFailed = "sync_failed"
        /// The capture ended early or its last batch may be missing.
        case incomplete
        /// Mouth crops are too dark for the lip-reading model.
        case lowLight = "low_light"
        /// Fewer than 98% of the expected mouth frames arrived.
        case mouthDropped = "mouth_dropped"
        /// Set by the label job: Whisper's transcript is more than 0.3 WER from the prompt, so the take is a misread.
        case transcriptMismatch = "transcript_mismatch"
    }

    public static let minTrackedRatio = 0.95
    public static let minFps = 55.0
    public static let minDuration = 0.4
    public static let minSpeech = 0.2
    public static let silentCeilingDb = -40.0
    public static let silentAllowance = 0.3
    /// Mean crop luma, of 255.
    public static let lowLightLuma = 60.0
    public static let minMouthReceived = 0.98

    /// - Parameters:
    ///   - duration: Seconds the user performed the prompt for, without any lead-in.
    ///   - expectedDuration: The prompt's expected length. Nil skips the upper bound.
    ///   - expectsMouth: The session asked for mouth video, so the video checks apply.
    public static func flags(metrics: CaptureMetrics, audio: [Int16], style: SpeechStyle,
                             duration: Double, expectedDuration: Double?, expectsMouth: Bool = false) -> [Flag] {
        var flags: [Flag] = []
        if metrics.trackedRatio < minTrackedRatio || metrics.measuredFps < minFps {
            flags.append(.poorTracking)
        }
        switch style {
        case .aloud, .whisper:
            if AudioLevel.speechDuration(audio) < minSpeech { flags.append(.noSpeech) }
        case .silent:
            if AudioLevel.duration(above: silentCeilingDb, in: audio) > silentAllowance { flags.append(.audibleInSilent) }
        case .negative:
            break
        }
        if duration < minDuration {
            flags.append(.tooShort)
        } else if let expectedDuration, duration > 2 * expectedDuration {
            flags.append(.tooLong)
        }
        if expectsMouth {
            if let luma = metrics.meanLuma, luma < lowLightLuma { flags.append(.lowLight) }
            if metrics.mouthFrameCount == 0 || metrics.mouthReceivedRatio < minMouthReceived { flags.append(.mouthDropped) }
        }
        return flags
    }

    public static func quality(_ flags: [Flag]) -> SessionManifest.Quality {
        SessionManifest.Quality(ok: flags.isEmpty, flags: flags.map(\.rawValue))
    }
}
