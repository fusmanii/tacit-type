import AppKit
import Foundation
import Observation
import TacitKit
import os

/// Toggle dictation: the first press of the hotkey sends `start`. The second press keeps a 300 ms tail,
/// sends `stop`, runs `DictationPipeline` and types the text into the focused app.
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

    /// A second press sooner than this after the first is an accidental double tap and cancels.
    static let minHold = 0.25
    static let tail: Duration = .milliseconds(300)
    /// M4 acceptance: key up → inserted.
    static let p50Budget = 1.1
    static let p95Budget = 1.5

    private(set) var state: State = .idle
    /// Rolling stop press → text inserted, seconds.
    private(set) var latency = LatencyStats()
    private(set) var lastBreakdown: Breakdown?
    private(set) var lastText: String?

    @ObservationIgnored private let devices: DeviceManager
    @ObservationIgnored private let sessions: SessionManager
    @ObservationIgnored private let pipeline: DictationPipeline
    @ObservationIgnored private let hud: HUDController
    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private var startPressAt: ContinuousClock.Instant?
    @ObservationIgnored private var helloAtStart: Hello?
    @ObservationIgnored private var accessibilityPoll: Task<Void, Never>?
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "dictation")

    init(devices: DeviceManager, sessions: SessionManager, pipeline: DictationPipeline, hud: HUDController,
         store: SessionStore) {
        self.devices = devices
        self.sessions = sessions
        self.pipeline = pipeline
        self.hud = hud
        self.store = store
    }

    private var engine: WhisperEngine { pipeline.engine }

    func handle(_ event: TriggerEvent) {
        switch event {
        case .began(.silentDictate):
            if state == .idle { hud.show(.message("Silent dictation arrives in M5."), for: 2) }
        case .ended(.silentDictate):
            break
        case .began(.dictate):
            switch state {
            case .idle: begin()
            case .listening(.dictate): end()
            case .listening, .processing: break
            }
        case .ended(.dictate):
            break
        }
    }

    // MARK: First press

    private func begin() {
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
        if !engine.isReady { engine.prepare() }
        do {
            helloAtStart = devices.peerHello
            try sessions.begin(mode: .dictate)
        } catch {
            hud.show(.error(error == .notConnected ? "iPhone not connected" : "The Recorder is capturing"), for: 2)
            return
        }
        startPressAt = .now
        state = .listening(.dictate)
        hud.show(.listening("Listening… press \(TriggerCenter.shortcutText(for: .dictate)) to stop"))
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

    private func end() {
        guard state == .listening(.dictate), let startPressAt else { return }
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
        Task { await finish(stopPressAt: stopPressAt) }
    }

    private func finish(stopPressAt: ContinuousClock.Instant) async {
        defer { state = .idle }
        try? await Task.sleep(for: Self.tail)
        hud.show(.processing("Transcribing…"))
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
        save(result, run: run)
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

    /// Keeps the session when "Save sessions for training" is on.
    private func save(_ result: SessionManager.CaptureResult, run: DictationPipeline.Run) {
        guard UserDefaults.standard.bool(forKey: DataSettings.saveSessionsKey) else { return }
        let recording = result.recording
        let metrics = result.metrics
        var flags = TakeQuality.flags(metrics: metrics, audio: recording.audio, style: run.style,
                                      duration: metrics.audioDuration, expectedDuration: nil,
                                      expectsMouth: result.streams.contains(.mouth))
        if result.endReason != .complete { flags.append(.incomplete) }
        let macVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var manifest = SessionManifest(
            sessionId: recording.sessionId, createdAt: .now, mode: .dictate, speechStyle: run.style,
            device: .init(model: helloAtStart?.deviceModel ?? "unknown", osVersion: helloAtStart?.osVersion ?? "unknown"),
            appVersions: .init(mac: macVersion, iphone: helloAtStart?.appVersion ?? "unknown"),
            quality: TakeQuality.quality(flags)
        )
        manifest.fill(from: metrics)
        let transcript = run.rawText.map {
            Transcript(text: $0, model: engine.model.modelId, createdAt: .now)
        }
        let session = StoredSession(manifest: manifest, frames: recording.frames, audio: recording.audio,
                                    mouth: recording.mouthFrames, transcript: transcript)
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
}
