import TacitKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Devices", systemImage: "iphone") { PlaceholderView(title: "Devices", milestone: "M1") }
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
    var body: some View {
        Form {
            LabeledContent("Protocol version", value: "\(Constants.protocolVersion)")
            LabeledContent("Feature schema", value: "\(Constants.featureSchemaVersion)")
            LabeledContent("Bonjour service", value: Constants.bonjourServiceType)
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
