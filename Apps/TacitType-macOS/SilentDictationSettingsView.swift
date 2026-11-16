import AppKit
import SwiftUI
import TacitKit

struct SilentDictationSettingsView: View {
    @Environment(ModelSidecar.self) private var sidecar
    @AppStorage(SilentDictationSettings.mlFolderKey) private var mlFolder = ""
    @AppStorage(SilentDictationSettings.checkpointKey) private var checkpoint = ""
    @AppStorage(SilentDictationSettings.cleanupKey) private var cleanup = true
    @State private var log: [String] = []

    var body: some View {
        Form {
            Section {
                LabeledContent("Sidecar") { status }
                if let health = sidecar.health {
                    LabeledContent("Model", value: "\(health.model), beam \(health.beam), on \(health.device.uppercased())")
                    LabeledContent("Checkpoint") {
                        Text(URL(filePath: health.checkpoint).lastPathComponent).textSelection(.enabled)
                    }
                    LabeledContent("Alignment correction") {
                        if health.correction != nil {
                            Text("Loaded, fitted \(fittedDate(health.correctionCreatedAt))")
                        } else {
                            Text("None. Run `python -m silentml.cropcheck --fit`.").foregroundStyle(.orange)
                        }
                    }
                    LabeledContent("Process", value: "pid \(health.pid)")
                }
                HStack {
                    Button("Restart Sidecar", action: sidecar.restart)
                    Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([SilentDictationSettings.logURL]) }
                }
            } header: {
                Text("Lip Reading")
            } footer: {
                Text("A Python process reads your lips on this Mac. It starts with Tacit Type and restarts if it crashes.")
            }

            Section {
                LabeledContent("ml folder") {
                    HStack {
                        Text(SilentDictationSettings.mlFolder?.path ?? "Not set")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(mlFolder.isEmpty ? .secondary : .primary)
                        Button("Choose…") { choose(folder: true) }
                        if !mlFolder.isEmpty { Button("Reset") { mlFolder = ""; sidecar.restart() } }
                    }
                }
                LabeledContent("Checkpoint") {
                    HStack {
                        Text(checkpoint.isEmpty ? "Pretrained Auto-AVSR" : URL(filePath: checkpoint).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(checkpoint.isEmpty ? .secondary : .primary)
                        Button("Choose…") { choose(folder: false) }
                        if !checkpoint.isEmpty { Button("Reset") { checkpoint = ""; sidecar.restart() } }
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("The ml folder holds silentml and its .venv (make ml-env). Pick a fine-tuned checkpoint here after M5e.")
            }

            Section {
                Toggle("Clean up guesses with Apple Intelligence", isOn: $cleanup)
                    .disabled(!SilentCleanup.isAvailable)
            } footer: {
                Text(SilentCleanup.isAvailable
                    ? "The on-device model picks the most likely sentence from the lip reader's five guesses. If it takes longer than 0.8 s, the top guess is typed."
                    : "Needs macOS 26 with Apple Intelligence turned on. Without it the top guess is typed.")
            }

            Section("Sidecar Log") {
                if log.isEmpty {
                    Text("Empty").foregroundStyle(.secondary)
                } else {
                    Text(log.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: sidecar.state) {
            while !Task.isCancelled {
                log = sidecar.logTail(20)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch sidecar.state {
        case .stopped: Label("Stopped", systemImage: "circle.fill").foregroundStyle(.secondary)
        case .starting: HStack { ProgressView().controlSize(.small); Text("Loading the model") }
        case .ready: Label("Ready", systemImage: "circle.fill").foregroundStyle(.green)
        case let .crashed(code): Label("Crashed (\(code)). Restarting…", systemImage: "circle.fill").foregroundStyle(.orange)
        case let .notConfigured(problem): Text(problem).foregroundStyle(.orange).lineLimit(3)
        case let .failed(problem): Text(problem).foregroundStyle(.red).lineLimit(4)
        }
    }

    private func fittedDate(_ iso: String?) -> String {
        guard let iso, let date = try? Date(iso, strategy: .iso8601) else { return "at an unknown time" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func choose(folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        if !folder { panel.allowedContentTypes = [.init(filenameExtension: "pth") ?? .data, .init(filenameExtension: "ckpt") ?? .data] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if folder { mlFolder = url.path } else { checkpoint = url.path }
        sidecar.restart()
    }
}
