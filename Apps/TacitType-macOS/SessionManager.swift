import Foundation
import Observation
import TacitKit
import os

/// Receives capture traffic from `DeviceManager`.
@MainActor
protocol CaptureMessageReceiver: AnyObject {
    func receive(_ message: Message)
    func linkDropped()
}

/// Sends `start` and `stop`, collects the session's face frames, audio and mouth video, and hands back a
/// finished `CaptureResult`.
///
/// TCP keeps order, so the `status` the iPhone sends after its last batch marks the session complete.
@MainActor
@Observable
final class SessionManager: CaptureMessageReceiver {
    enum State: Equatable {
        case idle
        case capturing(UUID)
        /// `stop` sent, waiting for the last batches.
        case finishing(UUID)
    }

    enum EndReason: Equatable, Sendable {
        case complete
        /// No end marker within `finishTimeout`. The result may be missing the last batch.
        case timedOut
        case disconnected
        /// The iPhone stopped without being asked (safety timeout, app left the foreground).
        case stoppedByIPhone
        case refused(String)
    }

    enum BeginError: Error, Equatable {
        case notConnected
        case alreadyCapturing
    }

    struct CaptureResult: Sendable {
        var mode: SessionMode
        var streams: [StreamKind]
        var recording: CaptureRecording
        var metrics: CaptureMetrics
        var endReason: EndReason
        /// `start` sent → first face frame, from the iPhone timestamp mapped through the clock offset.
        var startToFirstFrame: Double?
        var startToFirstTrackedFrame: Double?
        var startToFirstAudio: Double?
        /// Clock-sync round trip when the session ended. Half of it is roughly the time `start` spent on the wire.
        var clockRoundTrip: Double?
    }

    private(set) var state: State = .idle
    /// True once any face batch has arrived for the current session.
    private(set) var hasFirstFrame = false
    private(set) var lastResult: CaptureResult?
    /// Rolling `start` → first face frame, seconds, for Diagnostics.
    private(set) var firstFrameLatency = LatencyStats()

    @ObservationIgnored private let devices: DeviceManager
    @ObservationIgnored private var recording: CaptureRecording?
    @ObservationIgnored private var mode: SessionMode = .record
    @ObservationIgnored private var streams: [StreamKind] = StreamKind.all
    @ObservationIgnored private var startSentAt: Double = 0
    @ObservationIgnored private var endReason: EndReason?
    /// A status sent before our `start` may still be in flight, so idle only counts once the
    /// iPhone has said it's capturing this session.
    @ObservationIgnored private var sawCapturingStatus = false
    @ObservationIgnored private var finishWaiter: CheckedContinuation<Void, Never>?
    private static let finishTimeout: Duration = .milliseconds(1500)
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "session")

    init(devices: DeviceManager) {
        self.devices = devices
        devices.captureReceiver = self
    }

    var isActive: Bool { state != .idle }

    // MARK: Control

    @discardableResult
    func begin(mode: SessionMode, streams: [StreamKind] = StreamKind.all,
               promptText: String? = nil) throws(BeginError) -> UUID {
        guard state == .idle else { throw .alreadyCapturing }
        let sessionId = UUID()
        startSentAt = HostClock.now()
        guard devices.send(.start(StartCapture(sessionId: sessionId, mode: mode, streams: streams, promptText: promptText))) else {
            throw .notConnected
        }
        self.mode = mode
        self.streams = streams
        recording = CaptureRecording(sessionId: sessionId)
        endReason = nil
        sawCapturingStatus = false
        hasFirstFrame = false
        state = .capturing(sessionId)
        Self.log.info("Start \(sessionId, privacy: .public) (\(mode.rawValue, privacy: .public))")
        return sessionId
    }

    /// Sends `stop` and waits for the iPhone to finish sending. Returns nil if nothing was capturing.
    func end() async -> CaptureResult? {
        guard case let .capturing(sessionId) = state else { return nil }
        if endReason == nil {
            state = .finishing(sessionId)
            if devices.send(.stop(StopCapture(sessionId: sessionId))) {
                await waitForFinish()
            } else {
                endReason = .disconnected
            }
        }
        return complete()
    }

    private func waitForFinish() async {
        let timeout = Task {
            try? await Task.sleep(for: Self.finishTimeout)
            guard !Task.isCancelled else { return }
            self.finish(.timedOut)
        }
        await withCheckedContinuation { finishWaiter = $0 }
        timeout.cancel()
    }

    /// Records why the session ended and wakes `end()` if it's waiting.
    private func finish(_ reason: EndReason) {
        if endReason == nil { endReason = reason }
        finishWaiter?.resume()
        finishWaiter = nil
    }

    private func complete() -> CaptureResult? {
        guard let recording else { return nil }
        let metrics = recording.metrics
        let offset = devices.clockEstimate?.offset
        func sinceStart(_ iphoneTs: Double?) -> Double? {
            guard let iphoneTs, let offset else { return nil }
            return iphoneTs - offset - startSentAt
        }
        let result = CaptureResult(mode: mode, streams: streams, recording: recording, metrics: metrics,
                                   endReason: endReason ?? .complete,
                                   startToFirstFrame: sinceStart(metrics.firstFaceTs),
                                   startToFirstTrackedFrame: sinceStart(metrics.firstTrackedFaceTs),
                                   startToFirstAudio: sinceStart(metrics.firstAudioTs),
                                   clockRoundTrip: devices.clockEstimate?.roundTrip)
        if let latency = result.startToFirstFrame { firstFrameLatency.add(latency) }
        log(result)

        self.recording = nil
        lastResult = result
        state = .idle
        return result
    }

    private func log(_ result: CaptureResult) {
        let m = result.metrics
        let ms = { (value: Double?) in value.map { String(format: "%.0f ms", $0 * 1000) } ?? "n/a" }
        Self.log.notice("""
        Session \(result.recording.sessionId, privacy: .public) ended (\(String(describing: result.endReason), privacy: .public)): \
        start→face \(ms(result.startToFirstFrame), privacy: .public), start→audio \(ms(result.startToFirstAudio), privacy: .public), \
        \(m.frameCount) frames at \(m.measuredFps, format: .fixed(precision: 1)) fps, \
        dropped \(m.droppedFrames), tracked \(m.trackedRatio, format: .fixed(precision: 3)), audio gaps \(m.audioGapsFilled), \
        mouth \(m.mouthFrameCount)/\(m.expectedMouthFrames) at \(m.mouthFps, format: .fixed(precision: 1)) fps, \
        luma \(m.meanLuma ?? 0, format: .fixed(precision: 0))
        """)
    }

    // MARK: CaptureMessageReceiver

    func receive(_ message: Message) {
        guard var recording else { return }
        switch message {
        case let .faceBatch(batch):
            recording.append(batch)
            self.recording = recording
            if !hasFirstFrame, !batch.frames.isEmpty { hasFirstFrame = true }
        case let .audioChunk(chunk):
            recording.append(chunk)
            self.recording = recording
        case let .mouthBatch(batch):
            recording.append(batch)
            self.recording = recording
        case let .status(status):
            if status.state == .capturing {
                sawCapturingStatus = true
            } else if sawCapturingStatus {
                if case .finishing = state {
                    finish(.complete)
                } else if endReason == nil {
                    Self.log.notice("iPhone stopped capturing on its own (\(status.state.rawValue, privacy: .public))")
                    finish(.stoppedByIPhone)
                }
            }
        case let .error(error) where error.code == .busy || error.code == .captureFailed:
            finish(.refused(error.message))
        default:
            break
        }
    }

    func linkDropped() {
        guard recording != nil else { return }
        finish(.disconnected)
    }
}
