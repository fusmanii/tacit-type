import SwiftUI

struct RootView: View {
    @Environment(CamModel.self) private var model
    @Environment(LinkServer.self) private var link
    @State private var showingConnections = false

    var body: some View {
        switch model.state {
        case .unpaired:
            PairingCodeView(code: link.pairingCode)
        case .idle, .capturing:
            DockView(isCapturing: model.state == .capturing, isConnected: !link.connectedMacIds.isEmpty)
                .onLongPressGesture(minimumDuration: 0.8) { showingConnections = true }
                .sheet(isPresented: $showingConnections, onDismiss: link.closePairing) {
                    ConnectionsView()
                }
        case .error:
            ContentUnavailableView("Tacit Type can't run", systemImage: "exclamationmark.triangle",
                                   description: Text(model.errorMessage))
        }
    }
}

/// First launch, or after every Mac was forgotten.
struct PairingCodeView: View {
    let code: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Pair with your Mac")
                .font(.title2.bold())
            Text("On your Mac, open Tacit Type in the menu bar and choose Pair New iPhone. Then type this code.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            CodeText(code: code)
        }
        .padding(32)
    }
}

struct CodeText: View {
    let code: String?

    var body: some View {
        Text(code.map { "\($0.prefix(3)) \($0.suffix(3))" } ?? "––– –––")
            .font(.system(size: 52, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .contentTransition(.numericText())
            .accessibilityLabel(code.map { "Pairing code \($0.map(String.init).joined(separator: " "))" } ?? "No pairing code")
    }
}

/// Black dock screen with a small status dot. Green while capturing, grey while connected, dim when waiting.
/// Long-press anywhere for paired Macs.
struct DockView: View {
    let isCapturing: Bool
    var isConnected = true

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            Circle()
                .fill(isCapturing ? Color.green : Color.gray.opacity(isConnected ? 0.6 : 0.2))
                .frame(width: 8, height: 8)
                .padding(.top, 12)
        }
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(isCapturing ? "Capturing" : isConnected ? "Connected to Mac" : "Waiting for Mac")
        .accessibilityHint("Touch and hold to manage Macs")
    }
}

struct ConnectionsView: View {
    @Environment(LinkServer.self) private var link

    var body: some View {
        NavigationStack {
            List {
                Section("Paired Macs") {
                    ForEach(link.pairedMacs) { mac in
                        HStack {
                            Circle()
                                .fill(link.connectedMacIds.contains(mac.id) ? Color.green : Color.gray.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text(mac.name)
                            Spacer()
                            Text(link.connectedMacIds.contains(mac.id) ? "Connected" : "Not connected")
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Forget", role: .destructive) { link.forget(mac) }
                        }
                    }
                }

                Section {
                    if let code = link.pairingCode {
                        VStack(spacing: 8) {
                            Text("Type this code on the new Mac")
                                .foregroundStyle(.secondary)
                            CodeText(code: code)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } else {
                        Button("Pair Another Mac") { link.openPairing() }
                    }
                }
            }
            .navigationTitle("Macs")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview("Dock") { DockView(isCapturing: true) }
#Preview("Pairing") { PairingCodeView(code: "482913") }
