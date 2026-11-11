import TacitKit
import SwiftUI

@main
struct TacitTypeApp: App {
    @State private var devices = DeviceManager()

    var body: some Scene {
        MenuBarExtra("Tacit Type", systemImage: "mouth") {
            MenuContent()
                .environment(devices)
        }

        Window("Recorder", id: WindowID.recorder) {
            PlaceholderView(title: "Recorder", milestone: "M3")
        }

        Window("Commands", id: WindowID.commands) {
            PlaceholderView(title: "Commands", milestone: "M5")
        }

        Settings {
            SettingsView()
                .environment(devices)
        }
    }
}

enum WindowID {
    static let recorder = "recorder"
    static let commands = "commands"
}
