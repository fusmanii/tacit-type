import TacitKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Devices", systemImage: "iphone") { DevicesSettingsView() }
            Tab("Hotkeys", systemImage: "keyboard") { PlaceholderView(title: "Hotkeys", milestone: "M4") }
            Tab("Dictation", systemImage: "waveform") { PlaceholderView(title: "Dictation", milestone: "M4") }
            Tab("Commands", systemImage: "command") { PlaceholderView(title: "Commands", milestone: "M5") }
            Tab("Data", systemImage: "externaldrive") { PlaceholderView(title: "Data", milestone: "M3") }
            Tab("Diagnostics", systemImage: "stethoscope") { DiagnosticsView() }
        }
        .frame(width: 520, height: 340)
    }
}

private struct DiagnosticsView: View {
    @Environment(DeviceManager.self) private var devices

    var body: some View {
        Form {
            Section("Link") {
                if let clock = devices.clockEstimate {
                    LabeledContent("Round trip", value: String(format: "%.1f ms", clock.roundTrip * 1000))
                    LabeledContent("iPhone clock offset", value: String(format: "%+.3f s", clock.offset))
                } else {
                    LabeledContent("Clock sync", value: "Not connected")
                }
                LabeledContent("This Mac's id", value: devices.macId.uuidString)
                    .textSelection(.enabled)
            }
            Section("Versions") {
                LabeledContent("Protocol version", value: "\(Constants.protocolVersion)")
                LabeledContent("Feature schema", value: "\(Constants.featureSchemaVersion)")
                LabeledContent("Bonjour service", value: Constants.bonjourServiceType)
            }
        }
        .formStyle(.grouped)
    }
}

struct PlaceholderView: View {
    let title: String
    let milestone: String

    var body: some View {
        ContentUnavailableView(title, systemImage: "hammer", description: Text("Arrives in \(milestone)."))
            .frame(minWidth: 360, minHeight: 240)
    }
}
