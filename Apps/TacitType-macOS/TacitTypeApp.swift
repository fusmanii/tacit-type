import TacitKit
import SwiftUI

@main
struct TacitTypeApp: App {
    @State private var devices: DeviceManager
    @State private var sessions: SessionManager
    @State private var bench: CaptureBench
    @State private var recorder: RecorderModel
    @State private var engine: WhisperEngine
    @State private var calibration: GateCalibration
    @State private var dictation: DictationController
    @State private var labelJob: LabelJob
    @State private var gateEvaluation: GateEvaluation
    private let triggers = TriggerCenter()

    init() {
        let devices = DeviceManager()
        let sessions = SessionManager(devices: devices)
        let recorder = RecorderModel(devices: devices, sessions: sessions)
        let engine = WhisperEngine()
        let calibration = GateCalibration()
        let pipeline = DictationPipeline(engine: engine, calibration: calibration)
        let dictation = DictationController(devices: devices, sessions: sessions, pipeline: pipeline,
                                            hud: HUDController(), store: recorder.store)
        _devices = State(initialValue: devices)
        _sessions = State(initialValue: sessions)
        _bench = State(initialValue: CaptureBench(sessions: sessions))
        _recorder = State(initialValue: recorder)
        _engine = State(initialValue: engine)
        _calibration = State(initialValue: calibration)
        _dictation = State(initialValue: dictation)
        _labelJob = State(initialValue: LabelJob(engine: engine, store: recorder.store))
        _gateEvaluation = State(initialValue: GateEvaluation(pipeline: pipeline, store: recorder.store))

        triggers.handler = { dictation.handle($0) }
        triggers.add(HotkeyTrigger())
        engine.loadIfDownloaded()
        let store = recorder.store
        Task { await calibration.refresh(from: store) }
        recorder.onSaved = { prompt in
            if prompt.style == .negative { Task { await calibration.refresh(from: store) } }
        }
    }

    var body: some Scene {
        MenuBarExtra("Tacit Type", systemImage: "mouth") {
            MenuContent()
                .environment(devices)
        }

        Window("Pair iPhone", id: WindowID.pairing) {
            PairingView()
                .environment(devices)
        }
        .windowResizability(.contentSize)

        Window("Recorder", id: WindowID.recorder) {
            RecorderView()
                .environment(devices)
                .environment(recorder)
        }

        Settings {
            SettingsView()
                .environment(devices)
                .environment(sessions)
                .environment(bench)
                .environment(recorder)
                .environment(engine)
                .environment(calibration)
                .environment(dictation)
                .environment(labelJob)
                .environment(gateEvaluation)
        }
    }
}

enum WindowID {
    static let recorder = "recorder"
    static let pairing = "pairing"
}
