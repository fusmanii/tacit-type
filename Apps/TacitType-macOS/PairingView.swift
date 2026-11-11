import SwiftUI

/// "Pair New iPhone…" window. Lists iPhones that are showing a pairing code and takes the code.
struct PairingView: View {
    @Environment(DeviceManager.self) private var devices
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selection: UUID?
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    private var pairable: [DeviceManager.NearbyPhone] { devices.nearby.filter(\.canPair) }

    private var isPairing: Bool {
        if case .pairing = devices.pairingState { true } else { false }
    }

    var body: some View {
        Group {
            if case let .succeeded(name) = devices.pairingState {
                success(name)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            devices.resetPairingState()
            selection = pairable.first?.id
        }
        .onChange(of: pairable.map(\.id)) { _, ids in
            if selection.map(ids.contains) != true { selection = ids.first }
        }
        .onChange(of: selection) { codeFocused = selection != nil }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair New iPhone")
                .font(.title2.bold())

            if pairable.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for iPhones…")
                    }
                    Text("Open Tacit Type on your iPhone. It shows a code when it's ready to pair. If it's already paired with another Mac, touch and hold its screen and choose Pair Another Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Picker("iPhone", selection: $selection) {
                    ForEach(pairable) { phone in
                        Text(phone.name).tag(Optional(phone.id))
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(isPairing)

                TextField("6-digit code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 20, design: .monospaced))
                    .focused($codeFocused)
                    .disabled(isPairing)
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { code = digits }
                    }
                    .onSubmit(pair)

                if case let .failed(message) = devices.pairingState {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    devices.resetPairingState()
                    dismissWindow()
                }
                .keyboardShortcut(.cancelAction)
                Button(action: pair) {
                    if isPairing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Pair")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || code.count != 6 || isPairing)
            }
        }
    }

    private func success(_ name: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Paired with \(name)")
                .font(.title3.bold())
            Text("Tacit Type connects to it automatically whenever the app is open on your iPhone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Done") {
                devices.resetPairingState()
                dismissWindow()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
    }

    private func pair() {
        guard let selection, code.count == 6, !isPairing else { return }
        devices.pair(with: selection, code: code)
        code = ""
    }
}
