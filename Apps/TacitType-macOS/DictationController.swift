import AppKit
import Foundation
import Observation
import TacitKit
import os

/// Toggle dictation for both modes: the first press of a hotkey sends `start`. The second press keeps a
/// 300 ms tail, sends `stop`, runs `DictationPipeline` (Dictate) or `SilentDictationPipeline` (Silent
/// dictate), and types the text into the focused app.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case listening(TriggerMode)
        case processing
    }

    /// Stage times of the last dictation that reached Whisper, seconds.
    struct Breakdown: Equatable {
        var tailAndStop: Double
        var gate: Double
        var whisper: Double
        var cleanup: Double
        var insert: Double
        var total: Double
        var method: TextInserter.Method
    }

    /// Stage times of the last silent dictation that reached the lip reader, seconds.
    struct SilentBreakdown: Equatable {
        var tailAndStop: Double
        var gate: Double
        var write: Double
        var sidecar: Double
        var sidecarTimings: SidecarReply.Timings
        var cleanup: Double
        var insert: Double
        var total: Double
        var frames: Int
        var hypotheses: [String]
        var text: String
        var usedCleanup: Bool
        var method: TextInserter.Method
    }

    /// A second press sooner than this after the first is an accidental double tap and cancels.
    static let minHold = 0.25
    static let tail: Duration = .milliseconds(300)
    /// M4 acceptance: key up → inserted.
    static let p50Budget = 1.1
    static let p95Budget = 1.5
    /// M5 acceptance: key up → inserted for a 5 s silent utterance.
    static let silentBudget = 2.5

    private(set) var state: State = .idle
    /// Rolling stop press → text inserted, seconds.
    private(set) var latency = LatencyStats()
    private(set) var lastBreakdown: Breakdown?
    private(set) var lastText: String?
    /// Rolling stop press → text inserted for silent dictation, seconds.
    private(set) var silentLatency = LatencyStats()
    private(set) var lastSilent: SilentBreakdown?

    @ObservationIgnored private let devices: DeviceManager
    @ObservationIgnored private let sessions: SessionManager
    @ObservationIgnored private let pipeline: DictationPipeline
    @ObservationIgnored private let silent: SilentDictationPipeline
    @ObservationIgnored private let hud: HUDController
    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private var startPressAt: ContinuousClock.Instant?
    @ObservationIgnored private var helloAtStart: Hello?
    @ObservationIgnored private var accessibilityPoll: Task<Void, Never>?
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "dictation")

    init(devices: DeviceManager, sessions: SessionManager, pipeline: DictationPipeline,
         silent: SilentDictationPipeline, hud: HUDController, store: SessionStore) {
        self.devices = devices
        self.sessions = sessions
        self.pipeline = pipeline
        self.silent = silent
        self.hud = hud
        self.store = store
    }

    private var engine: WhisperEngine { pipeline.engine }

    func handle(_ event: TriggerEvent) {
        guard case let .began(mode) = event else { return }
        switch state {
        case .idle: begin(mode)
        case .listening(mode): end(mode)
        case .listening, .processing: break
        }
    }

    // MARK: First press

    private func begin(_ mode: TriggerMode) {
        guard state == .idle else { return }
        guard TextInserter.isTrusted else {
            TextInserter.requestTrust()
            waitForAccessibility()
            hud.show(.error("Allow Tacit Type in Privacy & Security → Accessibility."), for: 4)
            return
        }
        guard devices.isConnected else {
            hud.show(.error("iPhone not connected"), for: 2)
            return
        }
        if mode == .silentDictate {
            switch silent.sidecar.state {
            case .ready, .starting: break
            case .crashed: break
            case let .notConfigured(problem), let .failed(problem):
                hud.show(.error("Lip reading isn't available. \(problem)"), for: 4)
                return
            case .stopped:
                silent.sidecar.start()
            }
            SilentCleanup.prewarm()
        } else if !engine.isReady {
            engine.prepare()
        }
        do {
            helloAtStart = devices.peerHello
            try sessions.begin(mode: mode.sessionMode)
        } catch {
            hud.show(.error(error == .notConnected ? "iPhone not connected" : "The Recorder is capturing"), for: 2)
            return
        }
        startPressAt = .now
        state = .listening(mode)
        let verb = mode == .silentDictate ? "Watching" : "Listening"
        hud.show(.listening("\(verb)… press \(TriggerCenter.shortcutText(for: mode)) to stop"))
    }

    /// Polls until the user grants Accessibility, so the next dictation just works.
    private func waitForAccessibility() {
        guard accessibilityPoll == nil else { return }
        accessibilityPoll = Task {
            while !Task.isCancelled, !TextInserter.isTrusted {
                try? await Task.sleep(for: .seconds(1))
            }
            accessibilityPoll = nil
            if TextInserter.isTrusted { hud.show(.message("Accessibility allowed. Ready to dictate."), for: 2) }
        }
    }

    // MARK: Second press

    private func end(_ mode: TriggerMode) {
        guard state == .listening(mode), let startPressAt else { return }
        self.startPressAt = nil
        let stopPressAt = ContinuousClock.now
        if (stopPressAt - startPressAt).seconds < Self.minHold {
            state = .processing
            Task {
                _ = await sessions.end()
                hud.hide()
                state = .idle
            }
            return
        }
        state = .processing
        Task { await finish(mode, stopPressAt: stopPressAt) }
    }

    private func finish(_ mode: TriggerMode, stopPressAt: ContinuousClock.Instant) async {
        defer { state = .idle }
        try? await Task.sleep(for: Self.tail)
        hud.show(.processing(mode == .silentDictate ? "Reading lips…" : "Transcribing…"))
        guard let result = await sessions.end() else {
            hud.show(.error("The capture didn't finish"), for: 2)
            return
        }
        let tailAndStop = (ContinuousClock.now - stopPressAt).seconds
        switch result.endReason {
        case .disconnected: return hud.show(.error("The iPhone disconnected"), for: 2)
        case let .refused(reason): return hud.show(.error("The iPhone couldn't capture. \(reason)"), for: 3)
        case .complete, .timedOut, .stoppedByIPhone: break
        }
        if mode == .silentDictate {
            await finishSilent(result, stopPressAt: stopPressAt, tailAndStop: tailAndStop)
        } else {
            await transcribe(result, mode: .dictate, stopPressAt: stopPressAt, tailAndStop: tailAndStop)
        }
    }

    /// Spoken dictation, and silent dictation that turned out to be spoken aloud.
    private func transcribe(_ result: SessionManager.CaptureResult, mode: SessionMode,
                            stopPressAt: ContinuousClock.Instant, tailAndStop: Double) async {
        let recording = result.recording
        guard let audioT0 = recording.audioT0, !recording.audio.isEmpty else {
            return hud.show(.message("Didn't catch that"), for: 1.5)
        }

        if !engine.isReady {
            hud.show(.processing("Loading the speech model…"))
            let ready = await waitForModel()
            guard ready else {
                return hud.show(.error("The speech model couldn't load. See Settings → Dictation."), for: 3)
            }
        }

        let run: DictationPipeline.Run
        do {
            run = try await pipeline.run(frames: recording.frames, audio: recording.audio, audioT0: audioT0)
        } catch {
            Self.log.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
            return hud.show(.error("Dictation failed. \(error.localizedDescription)"), for: 3)
        }
        log(run, result: result)

        var method: TextInserter.Method?
        switch run.outcome {
        case let .text(text):
            hud.hide()
            let insertStart = ContinuousClock.now
            method = await TextInserter.insert(text, forcePasteFor: DictationSettings.pasteOverrides)
            let now = ContinuousClock.now
            let total = (now - stopPressAt).seconds
            latency.add(total)
            lastText = text
            lastBreakdown = Breakdown(tailAndStop: tailAndStop, gate: run.gateSeconds, whisper: run.whisperSeconds,
                                      cleanup: run.cleanupSeconds, insert: (now - insertStart).seconds, total: total,
                                      method: method ?? .paste)
            Self.log.notice("Stop press → inserted \(total * 1000, format: .fixed(precision: 0)) ms via \(method?.rawValue ?? "?", privacy: .public)")
            hud.show(.result(text), for: 1.5)
        case .nothingHeard, .hallucination:
            hud.show(.message("Didn't catch that"), for: 1.5)
        case .silentMouthing:
            hud.show(.message("No sound. Use Silent dictate?"), for: 2)
        }
        save(result, mode: mode, style: run.style, transcript: run.rawText.map {
            Transcript(text: $0, model: engine.model.modelId, createdAt: .now)
        })
    }

    /// Shows download progress in the HUD while the model gets ready.
    private func waitForModel() async -> Bool {
        let progress = Task {
            while !Task.isCancelled {
                if case let .downloading(fraction) = engine.state {
                    hud.show(.progress("Downloading the speech model", fraction))
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progress.cancel() }
        return await engine.waitUntilReady()
    }

    private func log(_ run: DictationPipeline.Run, result: SessionManager.CaptureResult) {
        let gate = run.gate
        Self.log.notice("""
        Dictation \(result.recording.sessionId, privacy: .public): \(String(describing: run.outcome), privacy: .private) \
        style \(run.style.rawValue, privacy: .public), gated out \(gate?.gatedOutSeconds ?? 0, format: .fixed(precision: 2)) s, \
        gate bypassed \(gate?.bypassed ?? false, privacy: .public), voiced \(gate?.voicedRatio ?? 0, format: .fixed(precision: 2)), \
        gate \(run.gateSeconds * 1000, format: .fixed(precision: 1)) ms, whisper \(run.whisperSeconds * 1000, format: .fixed(precision: 0)) ms
        """)
        if gate?.bypassed == true { Self.log.notice("gate_bypassed") }
    }

    // MARK: Training data

    private var savesSessions: Bool { UserDefaults.standard.bool(forKey: DataSettings.saveSessionsKey) }

    private func storedSession(_ result: SessionManager.CaptureResult, mode: SessionMode, style: SpeechStyle,
                               transcript: Transcript?) -> StoredSession {
        let recording = result.recording
        let metrics = result.metrics
        var flags = TakeQuality.flags(metrics: metrics, audio: recording.audio, style: style,
                                      duration: metrics.audioDuration, expectedDuration: nil,
                                      expectsMouth: result.streams.contains(.mouth))
        if result.endReason != .complete { flags.append(.incomplete) }
        let macVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var manifest = SessionManifest(
            sessionId: recording.sessionId, createdAt: .now, mode: mode, speechStyle: style,
            device: .init(model: helloAtStart?.deviceModel ?? "unknown", osVersion: helloAtStart?.osVersion ?? "unknown"),
            appVersions: .init(mac: macVersion, iphone: helloAtStart?.appVersion ?? "unknown"),
            quality: TakeQuality.quality(flags)
        )
        manifest.fill(from: metrics)
        return StoredSession(manifest: manifest, frames: recording.frames, audio: recording.audio,
                             mouth: recording.mouthFrames, transcript: transcript)
    }

    /// Keeps the session when "Save sessions for training" is on.
    private func save(_ result: SessionManager.CaptureResult, mode: SessionMode, style: SpeechStyle, transcript: Transcript?) {
        guard savesSessions else { return }
        let session = storedSession(result, mode: mode, style: style, transcript: transcript)
        let store = store
        Task.detached {
            do {
                try await store.write(session)
            } catch {
                Logger(subsystem: Constants.logSubsystem, category: "dictation")
                    .error("Couldn't save dictation session: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Silent dictation

    private func finishSilent(_ result: SessionManager.CaptureResult, stopPressAt: ContinuousClock.Instant,
                              tailAndStop: Double) async {
        let recording = result.recording
        guard !recording.mouthFrames.isEmpty else {
            return hud.show(.error("No mouth video arrived. Check the iPhone app."), for: 2.5)
        }
        let routing = await silent.route(frames: recording.frames, audio: recording.audio, audioT0: recording.audioT0)
        let start: Double?
        let end: Double?
        switch routing.route {
        case .nothingSeen, .tooShort:
            return hud.show(.message("Didn't catch that"), for: 1.5)
        case .spokeAloud:
            Self.log.notice("Silent dictation was voiced (\(routing.gate.voicedRatio, format: .fixed(precision: 2))), using Whisper")
            if !engine.isReady { engine.prepare() }
            return await transcribe(result, mode: .silent, stopPressAt: stopPressAt, tailAndStop: tailAndStop)
        case let .lipRead(windowStart, windowEnd):
            start = windowStart
            end = windowEnd
        }

        if !silent.sidecar.isReady {
            hud.show(.processing("Loading the lip-reading model…"))
            let deadline = ContinuousClock.now + .seconds(30)
            while !silent.sidecar.isReady, ContinuousClock.now < deadline {
                if case .failed = silent.sidecar.state { break }
                if case .notConfigured = silent.sidecar.state { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard silent.sidecar.isReady else {
                return hud.show(.error("The lip-reading model isn't running. See Settings → Silent Dictation."), for: 3)
            }
        }

        // The sidecar reads a session folder. When sessions are kept for training it reads the saved
        // one, otherwise a scratch copy that is deleted after the reply.
        let keep = savesSessions
        let session = storedSession(result, mode: .silent, style: .silent, transcript: nil)
        let target = keep ? store : SessionStore(root: SilentDictationSettings.scratchRoot)
        let writeStart = ContinuousClock.now
        let folder: URL
        do {
            folder = try await Task.detached { try await target.write(session) }.value
        } catch {
            Self.log.error("Couldn't write the silent session: \(error.localizedDescription, privacy: .public)")
            return hud.show(.error("Couldn't prepare the clip. \(error.localizedDescription)"), for: 3)
        }
        let write = (ContinuousClock.now - writeStart).seconds
        defer {
            if !keep { try? FileManager.default.removeItem(at: folder) }
        }

        let reading: SilentDictationPipeline.Reading
        do {
            reading = try await silent.read(folder: folder, start: start, end: end,
                                            appName: NSWorkspace.shared.frontmostApplication?.localizedName)
        } catch let error as ModelSidecar.TranscribeError {
            if case let .sidecar(failure) = error, failure.code == .tooShort {
                return hud.show(.message("Didn't catch that"), for: 1.5)
            }
            return hud.show(.error("Lip reading failed. \(error.localizedDescription)"), for: 3)
        } catch {
            Self.log.error("Lip reading failed: \(error.localizedDescription, privacy: .public)")
            return hud.show(.error("Lip reading failed. \(error.localizedDescription)"), for: 3)
        }
        guard !reading.text.isEmpty else { return hud.show(.message("Didn't catch that"), for: 1.5) }

        hud.hide()
        let insertStart = ContinuousClock.now
        let method = await TextInserter.insert(reading.text, forcePasteFor: DictationSettings.pasteOverrides)
        let now = ContinuousClock.now
        let total = (now - stopPressAt).seconds
        silentLatency.add(total)
        lastText = reading.text
        lastSilent = SilentBreakdown(
            tailAndStop: tailAndStop, gate: routing.seconds, write: write, sidecar: reading.sidecarSeconds,
            sidecarTimings: reading.sidecarTimings, cleanup: reading.cleanupSeconds, insert: (now - insertStart).seconds,
            total: total, frames: reading.frames, hypotheses: reading.hypotheses, text: reading.text,
            usedCleanup: reading.usedCleanup, method: method)
        Self.log.notice("Silent stop press → inserted \(total * 1000, format: .fixed(precision: 0)) ms via \(method.rawValue, privacy: .public)")
        if SilentDictation.isDark(meanLuma: result.metrics.meanLuma) {
            hud.show(.result("\(reading.text)  (too dark to read lips well)"), for: 2.5)
        } else {
            hud.show(.result(reading.text), for: 1.5)
        }

        // The text is the model's guess, not a label. Training uses promptText, which live dictation never has.
        if keep {
            let cleanup = reading.usedCleanup ? "+apple-on-device" : ""
            let transcript = Transcript(text: reading.text, model: "\(SilentDictationSettings.model)\(cleanup)", createdAt: .now)
            try? store.writeTranscript(transcript, at: folder)
        }
    }
}
