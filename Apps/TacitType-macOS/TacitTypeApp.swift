import TacitKit
import SwiftUI

@main
struct TacitTypeApp: App {
    @State private var devices: DeviceManager
    @State private var sessions: SessionManager
    @State private var bench: CaptureBench
    @State private var recorder: RecorderModel

    init() {
        let devices = DeviceManager()
        let sessions = SessionManager(devices: devices)
        _devices = State(initialValue: devices)
        _sessions = State(initialValue: sessions)
        _bench = State(initialValue: CaptureBench(sessions: sessions))
        _recorder = State(initialValue: RecorderModel(devices: devices, sessions: sessions))
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

        Window("Commands", id: WindowID.commands) {
            PlaceholderView(title: "Commands", milestone: "M5")
        }

        Settings {
            SettingsView()
                .environment(devices)
                .environment(sessions)
                .environment(bench)
                .environment(recorder)
        }
    }
}

enum WindowID {
    static let recorder = "recorder"
    static let commands = "commands"
    static let pairing = "pairing"
}
