import Foundation
import Observation
import TacitKit

/// Diagnostics → Mouth Gate. The M4 check that the gate doesn't hurt accuracy: on the latest
/// `takeCount` accepted aloud and whisper Recorder takes, Whisper's WER with the gate must be no more
/// than 1 point worse than without it.
@MainActor
@Observable
final class GateEvaluation {
    struct Report: Equatable {
        var takes: Int
        var gatedWer: Double
        var ungatedWer: Double
        /// Takes where the gate let nothing through.
        var gatedEmpty: Int

        var passed: Bool { takes >= GateEvaluation.takeCount && gatedWer - ungatedWer <= GateEvaluation.maxWerIncrease }
    }

    nonisolated static let takeCount = 20
    nonisolated static let maxWerIncrease = 0.01

    private(set) var progress: (done: Int, total: Int)?
    private(set) var report: Report?
    private(set) var problem: String?

    @ObservationIgnored private let pipeline: DictationPipeline
    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private var task: Task<Void, Never>?

    init(pipeline: DictationPipeline, store: SessionStore) {
        self.pipeline = pipeline
        self.store = store
    }

    var isRunning: Bool { task != nil }

    /// Newest accepted aloud and whisper sentence takes from the Recorder.
    nonisolated static func takes(in store: SessionStore) -> [URL] {
        let candidates = store.sessionFolders().compactMap { folder -> (URL, Date)? in
            guard let manifest = try? store.readManifest(at: folder), manifest.mode == .record, manifest.quality.ok,
                  manifest.speechStyle == .aloud || manifest.speechStyle == .whisper,
                  manifest.promptText != nil, manifest.promptId != RecorderPrompts.syncCheck.promptId
            else { return nil }
            return (folder, manifest.createdAt)
        }
        return candidates.sorted { $0.1 > $1.1 }.prefix(takeCount).map(\.0)
    }

    func start() {
        guard task == nil else { return }
        task = Task {
            defer { task = nil; progress = nil }
            await run()
        }
    }

    private func run() async {
        problem = nil
        report = nil
        guard await pipeline.engine.waitUntilReady() else {
            problem = "The speech model isn't ready. Check Settings → Dictation."
            return
        }
        let store = store
        let folders = await Task.detached { Self.takes(in: store) }.value
        guard !folders.isEmpty else {
            problem = "No accepted aloud or whisper takes yet. Record some in the Recorder."
            return
        }
        var gated: [(reference: String, hypothesis: String)] = []
        var ungated: [(reference: String, hypothesis: String)] = []
        var empty = 0
        for (index, folder) in folders.enumerated() {
            if Task.isCancelled { return }
            progress = (index, folders.count)
            do {
                let session = try await Task.detached { try store.read(at: folder) }.value
                guard let prompt = session.manifest.promptText, let audioT0 = session.manifest.firstAudioTs else { continue }
                let withGate = try await pipeline.run(frames: session.frames, audio: session.audio, audioT0: audioT0, cleanup: false)
                let withoutGate = try await pipeline.run(frames: session.frames, audio: session.audio, audioT0: audioT0,
                                                         useGate: false, cleanup: false)
                if withGate.text == nil { empty += 1 }
                gated.append((prompt, withGate.text ?? ""))
                ungated.append((prompt, withoutGate.text ?? ""))
            } catch {
                problem = "Couldn't evaluate \(folder.lastPathComponent). \(error.localizedDescription)"
                return
            }
        }
        guard let gatedWer = WordErrorRate.corpus(gated), let ungatedWer = WordErrorRate.corpus(ungated) else { return }
        report = Report(takes: gated.count, gatedWer: gatedWer, ungatedWer: ungatedWer, gatedEmpty: empty)
    }
}
