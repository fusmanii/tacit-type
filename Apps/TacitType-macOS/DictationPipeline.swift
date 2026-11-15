import Foundation
import Observation
import TacitKit
import os

/// The mouth-gate threshold θ, from the user's accepted "stay still" takes. Until there are any,
/// `MouthActivity.defaultThreshold`.
@MainActor
@Observable
final class GateCalibration {
    private(set) var measured: Double?
    private(set) var neutralTakes = 0

    var threshold: Double { measured ?? MouthActivity.defaultThreshold }

    func refresh(from store: SessionStore) async {
        let result = await Task.detached {
            let neutral = store.sessionFolders().compactMap { folder -> [FaceFrame]? in
                guard let manifest = try? store.readManifest(at: folder),
                      manifest.speechStyle == .negative, manifest.promptId == RecorderPrompts.neutral.promptId,
                      manifest.quality.ok
                else { return nil }
                return try? store.read(at: folder).frames
            }
            return (MouthActivity.threshold(neutral: neutral), neutral.count)
        }.value
        measured = result.0
        neutralTakes = result.1
    }
}

/// Audio → mouth gate → WhisperKit → cleanup (Step 2). Inserting the text is up to the caller.
@MainActor
final class DictationPipeline {
    struct Run: Sendable {
        enum Outcome: Sendable, Equatable {
            case text(String)
            /// No mouth movement, or no speech in the gated audio.
            case nothingHeard
            /// The mouth moved but almost nothing was audible.
            case silentMouthing
            /// Whisper produced only a blocklisted line.
            case hallucination(String)
        }

        var outcome: Outcome
        var gate: MouthGate.Result?
        var style: SpeechStyle
        /// Whisper's text before cleanup.
        var rawText: String?
        var gateSeconds: Double = 0
        var whisperSeconds: Double = 0
        var cleanupSeconds: Double = 0

        var text: String? {
            if case let .text(text) = outcome { text } else { nil }
        }
    }

    let engine: WhisperEngine
    let calibration: GateCalibration
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "dictation")

    init(engine: WhisperEngine, calibration: GateCalibration) {
        self.engine = engine
        self.calibration = calibration
    }

    /// - Parameters:
    ///   - useGate: False skips the mouth gate, for the gate evaluation.
    ///   - cleanup: False returns Whisper's text with only whitespace trimmed, for the gate evaluation.
    func run(frames: [FaceFrame], audio: [Int16], audioT0: Double,
             useGate: Bool = true, cleanup: Bool = true) async throws -> Run {
        let clock = ContinuousClock()
        let gateStart = clock.now
        var gated = audio
        var gate: MouthGate.Result?
        if useGate {
            let threshold = calibration.threshold
            let result = await Task.detached { MouthGate.apply(frames: frames, audio: audio, audioT0: audioT0, threshold: threshold) }.value
            gate = result
            switch result.decision {
            case .noActivity:
                return Run(outcome: .nothingHeard, gate: result, style: .aloud, gateSeconds: (clock.now - gateStart).seconds)
            case .silentMouthing:
                return Run(outcome: .silentMouthing, gate: result, style: .aloud, gateSeconds: (clock.now - gateStart).seconds)
            case let .speech(audio, _):
                gated = audio
            }
        }
        let speech = AudioLevel.speechDuration(gated)
        let style = DictationAudio.speechStyle(gatedAudio: gated)
        let prepared = DictationAudio.prepare(gated)
        let gateSeconds = (clock.now - gateStart).seconds
        guard speech >= TakeQuality.minSpeech else {
            return Run(outcome: .nothingHeard, gate: gate, style: style, gateSeconds: gateSeconds)
        }

        let whisperStart = clock.now
        let output = try await engine.transcribe(prepared, vocabulary: DictationSettings.vocabulary)
        let whisperSeconds = (clock.now - whisperStart).seconds

        var run = Run(outcome: .nothingHeard, gate: gate, style: style, rawText: output.text,
                      gateSeconds: gateSeconds, whisperSeconds: whisperSeconds)
        let clipDuration = Double(gated.count) / Constants.audioSampleRate
        if DictationText.isHallucination(output.text, clipDuration: clipDuration, speechDuration: speech) {
            run.outcome = .hallucination(output.text)
            return run
        }
        let cleanupStart = clock.now
        var text = cleanup ? DictationText.clean(output.text, replacements: DictationSettings.replacements)
            : output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanup, DictationSettings.polishEnabled, PunctuationPolish.isAvailable {
            text = await PunctuationPolish.polish(text)
        }
        run.cleanupSeconds = (clock.now - cleanupStart).seconds
        run.outcome = text.isEmpty ? .nothingHeard : .text(text)
        return run
    }
}

extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
