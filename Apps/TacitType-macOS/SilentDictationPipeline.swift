import Foundation
import TacitKit
import os

/// Mouth video → lip-reading sidecar → LLM cleanup (Step 3). Writing the session folder and inserting
/// the text are up to `DictationController`, which also does both for spoken dictation.
@MainActor
final class SilentDictationPipeline {
    struct Routing: Sendable {
        var gate: MouthGate.Result
        var route: SilentDictation.Route
        var seconds: Double
    }

    struct Reading: Sendable {
        var text: String
        /// The sidecar's guesses, best first, as the model wrote them.
        var hypotheses: [String]
        /// True when the LLM's sentence was used rather than the top guess.
        var usedCleanup: Bool
        var frames: Int
        /// Request sent → reply read, seconds.
        var sidecarSeconds: Double
        var sidecarTimings: SidecarReply.Timings
        var cleanupSeconds: Double
    }

    let sidecar: ModelSidecar
    let calibration: GateCalibration
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "silent")

    init(sidecar: ModelSidecar, calibration: GateCalibration) {
        self.sidecar = sidecar
        self.calibration = calibration
    }

    /// Runs the mouth gate over the clip and decides where it goes.
    func route(frames: [FaceFrame], audio: [Int16], audioT0: Double?) async -> Routing {
        let start = ContinuousClock.now
        let threshold = calibration.threshold
        // Without audio the gate can still find the mouth's regions. A start time is all it needs.
        let t0 = audioT0 ?? frames.first?.timestamp ?? 0
        let gate = await Task.detached {
            MouthGate.apply(frames: frames, audio: audio, audioT0: t0, threshold: threshold)
        }.value
        return Routing(gate: gate, route: SilentDictation.route(gate), seconds: (ContinuousClock.now - start).seconds)
    }

    /// Lip-reads the window of a written session folder and cleans up the guesses.
    func read(folder: URL, start: Double?, end: Double?, appName: String?) async throws -> Reading {
        let clock = ContinuousClock()
        let sent = clock.now
        let transcript = try await sidecar.transcribe(session: folder, start: start, end: end)
        let sidecarSeconds = (clock.now - sent).seconds
        let hypotheses = transcript.hypotheses.map(\.text)

        let cleanupStart = clock.now
        var picked: String?
        if SilentDictationSettings.cleanupEnabled {
            picked = await SilentCleanup.pick(from: hypotheses, appName: appName)
        }
        let base = picked ?? SilentDictation.fallbackText(hypotheses[0])
        let text = DictationText.clean(base, replacements: DictationSettings.replacements)
        let cleanupSeconds = (clock.now - cleanupStart).seconds
        Self.log.notice("""
        Lip-read \(transcript.frames) frames: sidecar \(sidecarSeconds * 1000, format: .fixed(precision: 0)) ms \
        (decode \(transcript.timings.decode * 1000, format: .fixed(precision: 0)) ms), \
        cleanup \(cleanupSeconds * 1000, format: .fixed(precision: 0)) ms, LLM used \(picked != nil, privacy: .public)
        """)
        return Reading(text: text, hypotheses: hypotheses, usedCleanup: picked != nil, frames: transcript.frames,
                       sidecarSeconds: sidecarSeconds, sidecarTimings: transcript.timings, cleanupSeconds: cleanupSeconds)
    }
}
