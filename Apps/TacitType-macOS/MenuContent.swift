import SwiftUI

struct MenuContent: View {
    @Environment(DeviceManager.self) private var devices
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(devices.statusLine)
        if devices.paired == nil || isRejected {
            Button("Pair New iPhone…") { open(WindowID.pairing) }
        }

        Divider()

        Text("Dictate: press \(TriggerCenter.shortcutText(for: .dictate)) to start and stop")
        Text("Silent dictate: press \(TriggerCenter.shortcutText(for: .silentDictate)) to start and stop")

        Divider()

        Button("Open Recorder…") { open(WindowID.recorder) }
        Button("Settings…") {
            NSApplication.shared.bringToFront { openSettings() }
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Tacit Type") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var isRejected: Bool {
        if case .rejected = devices.connectionState { true } else { false }
    }

    private func open(_ id: String) {
        NSApplication.shared.bringToFront { openWindow(id: id) }
    }
}

extension NSApplication {
    /// A menu-bar-only app isn't active when its menu is used, so a window it opens (or one that's
    /// already open) can land behind other apps. Activate first, open, then raise the new key window.
    func bringToFront(_ open: () -> Void) {
        activate(ignoringOtherApps: true)
        open()
        DispatchQueue.main.async {
            (self.keyWindow ?? self.windows.last { $0.isVisible && $0.canBecomeKey })?.orderFrontRegardless()
        }
    }
}
