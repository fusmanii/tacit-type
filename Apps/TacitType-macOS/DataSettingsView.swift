import SwiftUI
import TacitKit

enum DataSettings {
    /// When on, dictation and command sessions are saved as training data. Recorder takes always are.
    static let saveSessionsKey = "saveSessionsForTraining"
}

struct DataSettingsView: View {
    @Environment(RecorderModel.self) private var recorder
    @AppStorage(DataSettings.saveSessionsKey) private var saveSessions = false
    @State private var usage: Usage?
    @State private var confirmingDelete = false
    @State private var problem: String?

    private struct Usage: Equatable {
        var sessions: Int
        var flagged: Int
        var bytes: Int
    }

    private var store: SessionStore { recorder.store }

    var body: some View {
        Form {
            Section {
                Toggle("Save sessions for training", isOn: $saveSessions)
            } footer: {
                Text("Keeps the face and audio data of every dictation and command on this Mac. Takes you accept in the Recorder are always saved.")
            }

            Section("Sessions") {
                LabeledContent("Saved") {
                    if let usage {
                        Text("\(usage.sessions) sessions, \(usage.flagged) flagged · \(ByteCountFormatter.string(fromByteCount: Int64(usage.bytes), countStyle: .file))")
                            .monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                LabeledContent("Folder") {
                    Text(store.root.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(store.root)
                    }
                    Spacer()
                    Button("Delete All Sessions…", role: .destructive) { confirmingDelete = true }
                        .disabled(usage?.sessions == 0 && usage?.bytes == 0)
                }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .task(id: recorder.savedCount) { await refresh() }
        .confirmationDialog("Delete all saved sessions?", isPresented: $confirmingDelete) {
            Button("Delete All Sessions", role: .destructive) { deleteAll() }
        } message: {
            Text("This removes every recorded take from this Mac. You can't undo it.")
        }
    }

    private func refresh() async {
        let store = store
        usage = await Task.detached {
            let manifests = store.manifests()
            return Usage(sessions: manifests.count, flagged: manifests.count { !$0.quality.ok }, bytes: store.diskUsage())
        }.value
    }

    private func deleteAll() {
        do {
            try store.deleteAll()
            problem = nil
        } catch {
            problem = "Couldn't delete the sessions. \(error.localizedDescription)"
        }
        Task { await refresh() }
    }
}
