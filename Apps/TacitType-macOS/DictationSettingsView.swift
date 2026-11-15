import KeyboardShortcuts
import SwiftUI
import TacitKit

struct HotkeysSettingsView: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Dictate", name: .dictate)
                KeyboardShortcuts.Recorder("Silent dictate", name: .silentDictate)
            } footer: {
                Text("Press a shortcut once to start and again to stop. A second press within a quarter of a second cancels.")
            }
        }
        .formStyle(.grouped)
    }
}

struct DictationSettingsView: View {
    @Environment(WhisperEngine.self) private var engine
    @AppStorage(DictationSettings.wordsKey) private var words = ""
    @AppStorage(DictationSettings.replacementsKey) private var replacements = DictationSettings.defaultReplacements
    @AppStorage(DictationSettings.pasteOverridesKey) private var pasteOverrides = DictationSettings.defaultPasteOverrides
    @AppStorage(DictationSettings.polishKey) private var polish = false

    var body: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: Binding(get: { engine.model }, set: { engine.select($0) })) {
                    ForEach(DictationModel.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Status") { status }
                if engine.state == .notDownloaded || isFailed {
                    Button("Download Model") { engine.prepare() }
                }
            }

            Section {
                TextEditor(text: $words)
                    .font(.body.monospaced())
                    .frame(height: 60)
            } header: {
                Text("Words")
            } footer: {
                Text("Names and terms Whisper should know, separated by commas or new lines.")
            }

            Section {
                TextEditor(text: $replacements)
                    .font(.body.monospaced())
                    .frame(height: 70)
            } header: {
                Text("Replacements")
            } footer: {
                Text("One per line, written as \"said => typed\". \\n types a new line.")
            }

            Section {
                Toggle("Fix punctuation with Apple Intelligence", isOn: $polish)
                    .disabled(!PunctuationPolish.isAvailable)
            } footer: {
                Text(PunctuationPolish.isAvailable
                    ? "Uses the on-device model. If it takes longer than 0.4 s, the text is typed as Whisper heard it."
                    : "Needs macOS 26 with Apple Intelligence turned on.")
            }

            Section {
                TextEditor(text: $pasteOverrides)
                    .font(.body.monospaced())
                    .frame(height: 70)
            } header: {
                Text("Always paste in these apps")
            } footer: {
                Text("Bundle ids, one per line. Use this for apps where typed text doesn't appear. Tacit Type restores your clipboard after pasting.")
            }
        }
        .formStyle(.grouped)
    }

    private var isFailed: Bool {
        if case .failed = engine.state { true } else { false }
    }

    @ViewBuilder private var status: some View {
        switch engine.state {
        case .notDownloaded: Text("Not downloaded. It downloads the first time you dictate.").foregroundStyle(.secondary)
        case let .downloading(fraction): ProgressView(value: fraction) { Text("Downloading \(Int(fraction * 100))%").monospacedDigit() }
        case .loading: HStack { ProgressView().controlSize(.small); Text("Loading") }
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .failed(message): Text(message).foregroundStyle(.red).lineLimit(3)
        }
    }
}
