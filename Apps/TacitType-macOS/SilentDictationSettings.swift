import Foundation

/// Settings → Silent Dictation, stored in UserDefaults. The views bind to the same keys with `@AppStorage`.
enum SilentDictationSettings {
    static let mlFolderKey = "silentMLFolder"
    static let checkpointKey = "silentCheckpoint"
    static let cleanupKey = "silentLLMCleanup"

    /// Phase A's pick (M5b): Auto-AVSR at beam 10, with the alignment correction.
    static let model = "auto-avsr"
    static let beam = 10

    private static var defaults: UserDefaults { .standard }

    /// The repo's `ml` folder, where `.venv` and `silentml` live. Debug builds record their own
    /// checkout's folder in Info.plist, so each worktree finds its own environment.
    static var mlFolder: URL? {
        if let path = defaults.string(forKey: mlFolderKey), !path.isEmpty { return URL(filePath: path, directoryHint: .isDirectory) }
        return builtInMLFolder
    }

    static var builtInMLFolder: URL? {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "TacitMLFolder") as? String, !path.isEmpty else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// A fine-tuned checkpoint. Nil means the downloaded pretrained one.
    static var checkpoint: URL? {
        guard let path = defaults.string(forKey: checkpointKey), !path.isEmpty else { return nil }
        return URL(filePath: path)
    }

    /// On by default. Without the on-device model it does nothing.
    static var cleanupEnabled: Bool { defaults.object(forKey: cleanupKey) as? Bool ?? true }

    static let root = URL.applicationSupportDirectory.appending(path: "TacitType", directoryHint: .isDirectory)
    static let socketURL = root.appending(path: "sidecar.sock")
    static let logURL = root.appending(path: "logs/sidecar.log")
    /// Session folders written only for the sidecar to read, deleted after its reply.
    static let scratchRoot = root.appending(path: "tmp", directoryHint: .isDirectory)
}
