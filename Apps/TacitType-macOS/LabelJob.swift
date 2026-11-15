import Foundation
import Observation
import TacitKit
import os

/// Settings → Data → Label Sessions. Runs Whisper with word timestamps over every aloud and whisper
/// session that has no `transcript.json` and writes one. Takes whose transcript is more than 0.3 WER from
/// their prompt get the `transcript_mismatch` flag, so the Python loader drops them by default.
@MainActor
@Observable
final class LabelJob {
    enum Phase: Equatable {
        case idle
        case preparing
        case running(done: Int, total: Int)
        case finished(labelled: Int, flagged: Int, failed: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private let engine: WhisperEngine
    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "dictation")

    init(engine: WhisperEngine, store: SessionStore) {
        self.engine = engine
        self.store = store
    }

    var isRunning: Bool { task != nil }

    /// Sessions the job would label now.
    nonisolated static func unlabelled(in store: SessionStore) -> [URL] {
        store.sessionFolders().filter { folder in
            guard let manifest = try? store.readManifest(at: folder),
                  manifest.speechStyle == .aloud || manifest.speechStyle == .whisper
            else { return false }
            return !FileManager.default.fileExists(atPath: folder.appending(path: SessionStore.transcriptName).path)
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task {
            defer { task = nil }
            await run()
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func run() async {
        phase = .preparing
        guard await engine.waitUntilReady() else {
            phase = .failed("The speech model isn't ready. Check Settings → Dictation.")
            return
        }
        let store = store
        let folders = await Task.detached { Self.unlabelled(in: store) }.value
        var labelled = 0
        var flagged = 0
        var failed = 0
        for (index, folder) in folders.enumerated() {
            if Task.isCancelled { break }
            phase = .running(done: index, total: folders.count)
            do {
                let session = try await Task.detached { try store.read(at: folder) }.value
                let output = try await engine.transcribe(DictationAudio.prepare(session.audio), wordTimestamps: true)
                var manifest = session.manifest
                let wer = manifest.promptText.flatMap { WordErrorRate.wer(reference: $0, hypothesis: output.text) }
                try store.writeTranscript(Transcript(text: output.text, words: output.words, model: engine.model.modelId,
                                                     createdAt: .now, wer: wer), at: folder)
                let isSyncCheck = manifest.promptId == RecorderPrompts.syncCheck.promptId
                let flag = TakeQuality.Flag.transcriptMismatch.rawValue
                if let wer, wer > Transcript.maxPromptWer, !isSyncCheck, !manifest.quality.flags.contains(flag) {
                    manifest.quality.flags.append(flag)
                    manifest.quality.ok = false
                    try store.writeManifest(manifest, at: folder)
                    flagged += 1
                }
                labelled += 1
            } catch {
                failed += 1
                Self.log.error("Couldn't label \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        phase = .finished(labelled: labelled, flagged: flagged, failed: failed)
    }
}
