import Foundation
import Observation
import TacitKit
@preconcurrency import WhisperKit
import os

/// Settings → Dictation → Model.
enum DictationModel: String, CaseIterable, Identifiable, Sendable {
    case fast, accurate

    var id: Self { self }

    /// Folder names in `argmaxinc/whisperkit-coreml`, checked Nov 15, 2026.
    var modelId: String {
        switch self {
        case .fast: "openai_whisper-small.en"
        case .accurate: "openai_whisper-large-v3-v20240930_turbo"
        }
    }

    var title: String {
        switch self {
        case .fast: "Fast (small.en, about 250 MB)"
        case .accurate: "Accurate (large-v3 turbo, about 600 MB, M2 or newer)"
        }
    }
}

/// One Whisper result. Word times are seconds from the first sample of the audio passed in.
struct WhisperOutput: Sendable {
    var text: String
    var words: [Transcript.Word]
}

/// Owns the loaded WhisperKit pipeline. WhisperKit isn't Sendable, so it never leaves this actor.
actor WhisperRunner {
    private var kit: WhisperKit?
    private(set) var modelId: String?

    func load(folder: URL, modelId: String) async throws {
        kit = nil
        self.modelId = nil
        let config = WhisperKitConfig(modelFolder: folder.path(percentEncoded: false), verbose: false, logLevel: .error,
                                      prewarm: true, load: true, download: false)
        kit = try await WhisperKit(config)
        self.modelId = modelId
    }

    func transcribe(_ audio: [Float], vocabulary: [String], wordTimestamps: Bool) async throws -> WhisperOutput {
        guard let kit else { throw WhisperEngine.EngineError.notLoaded }
        var promptTokens: [Int]?
        if !vocabulary.isEmpty, let tokenizer = kit.tokenizer {
            promptTokens = tokenizer.encode(text: " " + vocabulary.joined(separator: ", "))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let options = DecodingOptions(
            language: "en", temperature: 0, skipSpecialTokens: true,
            withoutTimestamps: !wordTimestamps, wordTimestamps: wordTimestamps,
            promptTokens: promptTokens, suppressBlank: true, noSpeechThreshold: 0.6
        )
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let words = results.flatMap(\.segments).flatMap { $0.words ?? [] }.map {
            Transcript.Word(w: $0.word, start: Double($0.start), end: Double($0.end), p: Double($0.probability))
        }
        return WhisperOutput(text: text, words: words)
    }
}

/// Downloads, loads and runs the WhisperKit model the user picked. Models live in
/// `Application Support/TacitType/models`. The model loads at launch when it's already on disk,
/// and downloads the first time the user dictates or presses Download in Settings.
@MainActor
@Observable
final class WhisperEngine {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    enum EngineError: LocalizedError {
        case notLoaded

        var errorDescription: String? { "The speech model isn't loaded yet." }
    }

    static let modelSettingKey = "dictationModel"
    static let modelsRoot = URL.applicationSupportDirectory.appending(path: "TacitType/models", directoryHint: .isDirectory)
    private static let repo = "argmaxinc/whisperkit-coreml"
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "dictation")

    private(set) var state: State = .notDownloaded
    private(set) var model: DictationModel

    @ObservationIgnored let runner = WhisperRunner()
    @ObservationIgnored private var prepareTask: Task<Void, Never>?

    init() {
        model = UserDefaults.standard.string(forKey: Self.modelSettingKey).flatMap(DictationModel.init) ?? .fast
        state = isDownloaded(model) ? .loading : .notDownloaded
    }

    var isReady: Bool { state == .ready }

    /// Where HubApi puts a snapshot of the repo.
    private func folder(for model: DictationModel) -> URL {
        Self.modelsRoot.appending(path: "models/\(Self.repo)/\(model.modelId)", directoryHint: .isDirectory)
    }

    func isDownloaded(_ model: DictationModel) -> Bool {
        let folder = folder(for: model)
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }

    /// At launch: load the model if it's on disk. Never downloads.
    func loadIfDownloaded() {
        guard isDownloaded(model) else { return }
        prepare()
    }

    func select(_ newModel: DictationModel) {
        guard newModel != model else { return }
        model = newModel
        UserDefaults.standard.set(newModel.rawValue, forKey: Self.modelSettingKey)
        prepareTask?.cancel()
        prepareTask = nil
        state = isDownloaded(newModel) ? .loading : .notDownloaded
        if isDownloaded(newModel) { prepare() }
    }

    /// Downloads if needed, then loads. Safe to call again while it's running.
    func prepare() {
        if state == .ready || prepareTask != nil { return }
        let model = model
        prepareTask = Task {
            defer { prepareTask = nil }
            do {
                let folder: URL
                if isDownloaded(model) {
                    folder = self.folder(for: model)
                } else {
                    state = .downloading(0)
                    folder = try await WhisperKit.download(variant: model.modelId, downloadBase: Self.modelsRoot, from: Self.repo) { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor [weak self] in
                            if case .downloading = self?.state { self?.state = .downloading(fraction) }
                        }
                    }
                }
                guard !Task.isCancelled, self.model == model else { return }
                state = .loading
                let started = ContinuousClock.now
                try await runner.load(folder: folder, modelId: model.modelId)
                guard !Task.isCancelled, self.model == model else { return }
                Self.log.notice("Loaded \(model.modelId, privacy: .public) in \(started.duration(to: .now), privacy: .public)")
                state = .ready
            } catch {
                guard self.model == model else { return }
                Self.log.error("Couldn't prepare \(model.modelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Waits for `prepare()` to finish. Returns true when the model is ready.
    func waitUntilReady() async -> Bool {
        if state == .ready { return true }
        if case .failed = state { state = .notDownloaded }
        prepare()
        await prepareTask?.value
        return state == .ready
    }

    func transcribe(_ audio: [Float], vocabulary: [String] = [], wordTimestamps: Bool = false) async throws -> WhisperOutput {
        guard state == .ready else { throw EngineError.notLoaded }
        return try await runner.transcribe(audio, vocabulary: vocabulary, wordTimestamps: wordTimestamps)
    }

}
