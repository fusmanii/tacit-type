import TacitKit
import SwiftUI

struct DevicesSettingsView: View {
    @Environment(DeviceManager.self) private var devices
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingForget = false

    var body: some View {
        Form {
            Section("Paired iPhone") {
                if let paired = devices.paired {
                    LabeledContent(paired.name) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(devices.isConnected ? Color.green : Color.gray.opacity(0.5))
                                .frame(width: 8, height: 8)
                            Text(stateText)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let status = devices.lastStatus {
                        LabeledContent("Battery", value: batteryText(status))
                        LabeledContent("Temperature", value: status.thermalState.rawValue.capitalized)
                    }
                    if case .rejected = devices.connectionState {
                        Text("This iPhone forgot this Mac. Pair again to reconnect.")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("Forget iPhone…", role: .destructive) { confirmingForget = true }
                    }
                } else {
                    Text("No iPhone paired.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Pair New iPhone…") {
                        NSApplication.shared.bringToFront { openWindow(id: WindowID.pairing) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget \(devices.paired?.name ?? "iPhone")?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive) { devices.forgetPairedPhone() }
        } message: {
            Text("This Mac and the iPhone delete their shared key. You'll need a new code to pair again.")
        }
    }

    private var stateText: String {
        switch devices.connectionState {
        case .notPaired: "Not paired"
        case .searching: "Not nearby"
        case .connecting: "Connecting…"
        case .connected: devices.isPathViable ? "Connected" : "Interrupted"
        case .rejected: "Rejected"
        }
    }

    private func batteryText(_ status: TacitKit.DeviceStatus) -> String {
        let level = status.batteryLevel < 0 ? "Unknown" : "\(Int((status.batteryLevel * 100).rounded()))%"
        return status.isCharging ? "\(level), charging" : level
    }
}
