import AVFoundation
import Foundation
import Observation
import TacitKit
import os

/// Runs one Recorder sitting: a training sitting (sync check, aloud and silent sentences, neutral) or
/// the test-set sitting. Each take is captured, checked, reviewed and saved as a session folder on accept.
@MainActor
@Observable
final class RecorderModel {
    enum SittingKind: Equatable {
        case training, testSet
    }

    enum Phase: Equatable {
        /// Prompt on screen, waiting for Space.
        case ready
        case countdown(Int)
        case capturing(startedAt: Date, endsAt: Date)
        /// `stop` sent, waiting for the last batches.
        case finishing
        case review
        case sittingDone
    }

    enum Key {
        case space, redo, accept, discard, skip
    }

    struct Take {
        var prompt: RecorderPrompt
        /// Ready to save. The manifest already carries the metrics and the quality flags.
        var session: StoredSession
        var flags: [TakeQuality.Flag]
        var sync: SyncCheck.Result?
        /// The sync check run against the mouth video instead of the face frames.
        var videoSync: SyncCheck.Result?
        var trace: ReviewTrace
        var mouth: MouthReview?
        var duration: Double
    }

    struct SyncRun: Identifiable {
        let id = UUID()
        /// Nil when the check found no correlation.
        var lagMs: Double?
        var videoLagMs: Double?

        var passed: Bool { lagMs.map { abs($0) < SyncCheck.maxLagMs } ?? false }
        var videoPassed: Bool { videoLagMs.map { abs($0) < SyncCheck.maxLagMs } ?? false }
    }

    private(set) var blocks: [RecorderBlock] = []
    private(set) var blockIndex = 0
    /// Index of the next prompt in each block.
    private(set) var positions: [Int] = []
    private(set) var phase: Phase = .ready
    private(set) var take: Take?
    private(set) var message: String?
    /// Every sync check run since launch, newest last, whether or not it was accepted.
    private(set) var syncRuns: [SyncRun] = []
    /// The accepted sync check's lag. Stored in every later manifest of the sitting.
    private(set) var sittingOffsetMs: Double?
    private(set) var savedCount = 0
    private(set) var sittingId = UUID()
    private(set) var sittingKind: SittingKind = .training

    let store: SessionStore
    /// Called after a take is saved, with its prompt. The app uses it to recalibrate the mouth gate.
    @ObservationIgnored var onSaved: ((RecorderPrompt) -> Void)?

    @ObservationIgnored private let devices: DeviceManager
    @ObservationIgnored private let sessions: SessionManager
    @ObservationIgnored private var flow: Task<Void, Never>?
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var helloAtStart: Hello?
    /// One count of the 3-2-1. `start` goes out as the last count begins, so the TrueDepth
    /// camera (about 420 ms to power on) is running by the time the user starts.
    private static let countdownStep: Duration = .milliseconds(800)
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "session")

    init(devices: DeviceManager, sessions: SessionManager, store: SessionStore = SessionStore()) {
        self.devices = devices
        self.sessions = sessions
        self.store = store
    }

    // MARK: Sitting

    var currentBlock: RecorderBlock? { blocks.indices.contains(blockIndex) ? blocks[blockIndex] : nil }

    var currentPrompt: RecorderPrompt? {
        guard let block = currentBlock, block.prompts.indices.contains(positions[blockIndex]) else { return nil }
        return block.prompts[positions[blockIndex]]
    }

    /// True when the last five sync checks all landed under 20 ms. This is the M3 check.
    var syncPassedFiveInARow: Bool {
        syncRuns.count >= 5 && syncRuns.suffix(5).allSatisfy(\.passed)
    }

    /// The same for the mouth video. This is the M3b check.
    var videoSyncPassedFiveInARow: Bool {
        syncRuns.count >= 5 && syncRuns.suffix(5).allSatisfy(\.videoPassed)
    }

    /// The test prompts from `test.txt` in the app bundle. Empty until that list exists.
    var testPrompts: [(id: String, text: String)] { Self.bundledPrompts("test", prefix: "test") }

    var canSwitchBlock: Bool { phase == .ready || phase == .sittingDone }

    func prepareIfNeeded() {
        if blocks.isEmpty { newSitting() }
    }

    func newSitting() {
        guard canSwitchBlock else { return }
        let harvard = Self.bundleText("harvard").map(RecorderPrompts.harvardSentences(from:)) ?? []
        if harvard.isEmpty { Self.log.fault("harvard.txt is missing from the app bundle") }
        let sentences = harvard + Self.bundledPrompts("everyday", prefix: "everyday")
        let recorded = Set(store.manifests()
            .filter { $0.mode == .record && $0.speechStyle == .aloud && $0.quality.ok }
            .compactMap(\.promptId))
        var generator = SystemRandomNumberGenerator()
        start(RecorderPrompts.sitting(sentences: sentences, alreadyRecorded: recorded, using: &generator), kind: .training)
    }

    /// The held-out test set, in a sitting of its own. Does nothing until `test.txt` exists.
    func newTestSitting() {
        guard canSwitchBlock else { return }
        let prompts = testPrompts
        guard !prompts.isEmpty else {
            message = "There's no test prompt list yet. Add ml/prompts/test.txt and rebuild."
            return
        }
        var generator = SystemRandomNumberGenerator()
        start(RecorderPrompts.testSitting(prompts: prompts, using: &generator), kind: .testSet)
    }

    private func start(_ newBlocks: [RecorderBlock], kind: SittingKind) {
        blocks = newBlocks
        sittingKind = kind
        positions = Array(repeating: 0, count: blocks.count)
        blockIndex = 0
        sittingId = UUID()
        sittingOffsetMs = nil
        savedCount = 0
        take = nil
        message = nil
        phase = .ready
    }

    private static func bundleText(_ name: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static func bundledPrompts(_ name: String, prefix: String) -> [(id: String, text: String)] {
        bundleText(name).map { RecorderPrompts.prompts(from: $0, prefix: prefix) } ?? []
    }

    func select(block index: Int) {
        guard canSwitchBlock, blocks.indices.contains(index) else { return }
        blockIndex = index
        message = nil
        phase = currentPrompt == nil ? .sittingDone : .ready
    }

    // MARK: Keys

    /// Returns false when the key does nothing in the current phase.
    @discardableResult
    func handle(_ key: Key) -> Bool {
        switch (key, phase) {
        case (.space, .ready): startTake()
        case (.space, .countdown): flow?.cancel()
        case (.space, .capturing): finishTake()
        case (.space, .review): togglePlayback()
        case (.redo, .review): startTake()
        case (.accept, .review): accept()
        case (.discard, .review): discard()
        case (.skip, .ready): advance()
        default: return false
        }
        return true
    }

    // MARK: Take flow

    private func startTake() {
        guard let prompt = currentPrompt else { return }
        guard devices.isConnected else {
            message = "iPhone not connected. Open Tacit Type on your iPhone."
            phase = .ready
            return
        }
        stopPlayback()
        take = nil
        message = nil
        flow = Task { await countDownAndCapture(prompt) }
    }

    private func countDownAndCapture(_ prompt: RecorderPrompt) async {
        for count in [3, 2, 1] {
            phase = .countdown(count)
            if count == 1 {
                do {
                    helloAtStart = devices.peerHello
                    try sessions.begin(mode: .record, promptText: prompt.text)
                } catch {
                    fail(error == .notConnected ? "iPhone not connected. Open Tacit Type on your iPhone."
                        : "Another capture is running. Wait for it to finish.")
                    return
                }
            }
            try? await Task.sleep(for: Self.countdownStep)
            if Task.isCancelled {
                phase = .finishing
                _ = await sessions.end()
                phase = .ready
                return
            }
        }
        let now = Date.now
        phase = .capturing(startedAt: now, endsAt: now + prompt.timeLimit)
        limitTask = Task {
            try? await Task.sleep(for: .seconds(prompt.timeLimit))
            if !Task.isCancelled { finishTake() }
        }
    }

    private func finishTake() {
        guard case let .capturing(startedAt, _) = phase, let prompt = currentPrompt else { return }
        limitTask?.cancel()
        let duration = Date.now.timeIntervalSince(startedAt)
        phase = .finishing
        flow = Task {
            guard let result = await sessions.end() else {
                fail("The capture ended before it could be saved.")
                return
            }
            review(result, prompt: prompt, duration: duration)
        }
    }

    private func review(_ result: SessionManager.CaptureResult, prompt: RecorderPrompt, duration: Double) {
        switch result.endReason {
        case .disconnected: return fail("The iPhone disconnected during the take.")
        case let .refused(reason): return fail("The iPhone couldn't capture. \(reason)")
        case .complete, .timedOut, .stoppedByIPhone: break
        }
        let recording = result.recording
        guard !recording.frames.isEmpty, !recording.audio.isEmpty, let audioT0 = recording.audioT0 else {
            return fail("No face or audio data arrived from the iPhone.")
        }

        let expectsMouth = result.streams.contains(.mouth)
        var flags = TakeQuality.flags(metrics: result.metrics, audio: recording.audio, style: prompt.style,
                                      duration: duration, expectedDuration: prompt.expectedDuration,
                                      expectsMouth: expectsMouth)
        if result.endReason != .complete { flags.append(.incomplete) }

        let mouthPixels = recording.mouthPixels()
        var sync: SyncCheck.Result?
        var videoSync: SyncCheck.Result?
        if currentBlock?.kind == .syncCheck {
            sync = SyncCheck.measure(frames: recording.frames, audio: recording.audio, audioT0: audioT0)
            if let sync {
                if !sync.passed { flags.append(.syncOffset) }
            } else {
                flags.append(.syncFailed)
            }
            if !mouthPixels.isEmpty {
                videoSync = SyncCheck.measureVideo(times: recording.mouthFrames.map(\.timestamp), pixels: mouthPixels,
                                                   audio: recording.audio, audioT0: audioT0)
                if let videoSync, !videoSync.passed, !flags.contains(.syncOffset) { flags.append(.syncOffset) }
            }
            syncRuns.append(SyncRun(lagMs: sync?.lagMs, videoLagMs: videoSync?.lagMs))
        }

        let macVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var manifest = SessionManifest(
            sessionId: recording.sessionId, createdAt: .now, mode: .record, speechStyle: prompt.style,
            promptId: prompt.promptId, promptText: prompt.text, sittingId: sittingId,
            device: .init(model: helloAtStart?.deviceModel ?? "unknown", osVersion: helloAtStart?.osVersion ?? "unknown"),
            appVersions: .init(mac: macVersion, iphone: helloAtStart?.appVersion ?? "unknown"),
            measuredAvOffsetMs: sync?.lagMs ?? sittingOffsetMs,
            quality: TakeQuality.quality(flags)
        )
        manifest.fill(from: result.metrics)

        let trace = ReviewTrace(frames: recording.frames, audio: recording.audio, audioT0: audioT0)
        take = Take(prompt: prompt,
                    session: StoredSession(manifest: manifest, frames: recording.frames, audio: recording.audio,
                                           mouth: recording.mouthFrames),
                    flags: flags, sync: sync, videoSync: videoSync, trace: trace,
                    mouth: MouthReview(times: recording.mouthFrames.map { $0.timestamp - trace.origin }, pixels: mouthPixels),
                    duration: duration)
        phase = .review
        if prompt.style != .silent { play() }
    }

    private func fail(_ text: String) {
        message = text
        take = nil
        phase = .ready
    }

    private func accept() {
        guard let take else { return }
        stopPlayback()
        phase = .finishing
        flow = Task {
            do {
                let folder = try await store.write(take.session)
                Self.log.info("Saved take \(take.prompt.promptId, privacy: .public) to \(folder.path, privacy: .public)")
            } catch {
                message = "Couldn't save the take. \(error.localizedDescription)"
                phase = .review
                return
            }
            savedCount += 1
            onSaved?(take.prompt)
            if currentBlock?.kind == .syncCheck, let lag = take.sync?.lagMs { sittingOffsetMs = lag }
            phase = .ready
            advance()
        }
    }

    private func discard() {
        stopPlayback()
        take = nil
        phase = .ready
    }

    /// Moves to the next prompt, then to the next block with prompts left.
    private func advance() {
        stopPlayback()
        take = nil
        message = nil
        guard currentPrompt != nil else { return }
        positions[blockIndex] += 1
        if currentPrompt == nil {
            let order = Array(blocks.indices[blockIndex...]) + Array(blocks.indices[..<blockIndex])
            guard let next = order.first(where: { positions[$0] < blocks[$0].prompts.count }) else {
                phase = .sittingDone
                return
            }
            blockIndex = next
        }
        phase = .ready
    }

    // MARK: Playback

    /// Seconds from the start of the review strip, while the take is playing.
    var playheadTime: Double? {
        guard let player, player.isPlaying, let take else { return nil }
        return player.currentTime + take.trace.audioOffset
    }

    /// The mouth crop to show: the one under the playhead, or the middle of the take when not playing.
    func mouthImage(at time: Double?) -> CGImage? {
        guard let mouth = take?.mouth, !mouth.images.isEmpty else { return nil }
        guard let time else { return mouth.images[mouth.images.count / 2] }
        let index = mouth.times.lastIndex { $0 <= time } ?? 0
        return mouth.images[index]
    }

    private func play() {
        guard let take else { return }
        player = try? AVAudioPlayer(data: WavFile.encode(take.session.audio))
        player?.play()
    }

    private func togglePlayback() {
        if player?.isPlaying == true { stopPlayback() } else { play() }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
    }
}

/// What the review strip draws: the audio waveform with the `jawOpen` and `mouthClose` curves
/// on one time axis that starts at the earlier of the first frame and the first audio sample.
struct ReviewTrace {
    struct Point {
        var time: Double
        var value: Double
    }

    static let bins = 600

    var duration: Double
    /// iPhone host-clock time of the strip's left edge.
    var origin: Double
    /// Peak level per bin, scaled so the loudest bin is 1. Quiet takes stay small.
    var waveform: [Double]
    var jawOpen: [Point]
    var mouthClose: [Point]
    /// Time of the first audio sample on the strip's axis.
    var audioOffset: Double

    init(frames: [FaceFrame], audio: [Int16], audioT0: Double) {
        let rate = Constants.audioSampleRate
        let origin = min(frames.first?.timestamp ?? audioT0, audioT0)
        let end = max(frames.last?.timestamp ?? audioT0, audioT0 + Double(audio.count) / rate)
        let duration = max(end - origin, 0.001)
        self.duration = duration
        self.origin = origin
        audioOffset = audioT0 - origin

        var peaks = [Double](repeating: 0, count: Self.bins)
        for (index, sample) in audio.enumerated() {
            let time = audioOffset + Double(index) / rate
            let bin = min(Self.bins - 1, Int(time / duration * Double(Self.bins)))
            peaks[bin] = max(peaks[bin], abs(Double(sample)) / 32_768)
        }
        // −34 dBFS floor, so the hiss of a silent take isn't stretched to full height.
        let scale = max(peaks.max() ?? 0, 0.02)
        waveform = peaks.map { $0 / scale }

        let jaw = Constants.blendShapeOrder.firstIndex(of: "jawOpen")!
        let close = Constants.blendShapeOrder.firstIndex(of: "mouthClose")!
        let tracked = frames.filter { $0.trackingFlags.contains(.isTracked) }
        jawOpen = tracked.map { Point(time: $0.timestamp - origin, value: Double($0.blendShapes[jaw])) }
        mouthClose = tracked.map { Point(time: $0.timestamp - origin, value: Double($0.blendShapes[close])) }
    }
}

/// The mouth crops of a take, ready to draw in step with the review strip.
struct MouthReview {
    /// Seconds on the review strip's axis.
    var times: [Double]
    var images: [CGImage]

    init(times: [Double], pixels: [[UInt8]]) {
        self.times = times
        images = pixels.compactMap { Self.image($0) }
        if images.count != times.count { images = [] }
    }

    static func image(_ pixels: [UInt8], size: Int = Constants.mouthCropSize) -> CGImage? {
        guard pixels.count == size * size, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
