import SwiftUI

struct MenuContent: View {
    @Environment(DeviceManager.self) private var devices
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(devices.statusLine)

        Divider()

        Text("Dictate: hold ⌃⌥Space")
        Text("Command: hold ⌃⌥C")

        Divider()

        Button("Open Recorder…") { open(WindowID.recorder) }
        Button("Commands…") { open(WindowID.commands) }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")

        Divider()

        Button("Quit Tacit Type") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApplication.shared.activate()
    }
}
