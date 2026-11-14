import Foundation
import Observation
import TacitKit

/// Runs the M2 capture checks from Diagnostics: start latency over 20 tries and one 60 s session.
@MainActor
@Observable
final class CaptureBench {
    enum Phase: Equatable {
        case idle
        case measuringLatency(done: Int, of: Int)
        /// `endsAt` passes before the phase ends, while the last batches arrive.
        case recording(startedAt: Date, endsAt: Date)
    }

    struct LatencyRun: Equatable {
        /// Mac sends `start` → first face frame. This is what M2 checks.
        var stats = LatencyStats()
        /// The same minus half the clock-sync round trip: roughly `start` arriving → first frame,
        /// which is the part the iPhone controls.
        var onIPhone = LatencyStats()
        var failures: [String] = []
    }

    static let latencyTries = 20
    static let latencyBudget = 0.45
    static let sessionSeconds = 60
    static let minFps = 58.0
    static let maxDroppedRatio = 0.01

    private(set) var phase: Phase = .idle
    private(set) var latency: LatencyRun?
    private(set) var session: SessionManager.CaptureResult?
    private(set) var problem: String?

    @ObservationIgnored private let sessions: SessionManager
    @ObservationIgnored private var task: Task<Void, Never>?

    init(sessions: SessionManager) {
        self.sessions = sessions
    }

    var isRunning: Bool { phase != .idle }

    func measureLatency() {
        run {
            var run = LatencyRun()
            for attempt in 0 ..< Self.latencyTries {
                guard !Task.isCancelled else { break }
                self.phase = .measuringLatency(done: attempt, of: Self.latencyTries)
                do {
                    try self.sessions.begin(mode: .record)
                } catch {
                    run.failures.append("Try \(attempt + 1): \(error)")
                    break
                }
                let deadline = ContinuousClock.now + .seconds(2)
                while !self.sessions.hasFirstFrame, ContinuousClock.now < deadline, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                guard let result = await self.sessions.end() else { break }
                if let value = result.startToFirstFrame {
                    run.stats.add(value)
                    run.onIPhone.add(value - (result.clockRoundTrip ?? 0) / 2)
                } else {
                    run.failures.append("Try \(attempt + 1): \(Self.describe(result))")
                }
                self.latency = run
                // Let ARKit settle between tries so each start is cold-ish, like a real key press.
                try? await Task.sleep(for: .milliseconds(500))
            }
            self.latency = run
        }
    }

    func recordSession() {
        run {
            do {
                try self.sessions.begin(mode: .record)
            } catch {
                self.problem = "Couldn't start: \(error)"
                return
            }
            let now = Date.now
            self.phase = .recording(startedAt: now, endsAt: now + Double(Self.sessionSeconds))
            try? await Task.sleep(for: .seconds(Self.sessionSeconds))
            self.session = await self.sessions.end()
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(_ body: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        problem = nil
        task = Task {
            await body()
            if sessions.isActive { _ = await sessions.end() }
            phase = .idle
            task = nil
        }
    }

    private static func describe(_ result: SessionManager.CaptureResult) -> String {
        switch result.endReason {
        case let .refused(message): "refused: \(message)"
        case .disconnected: "iPhone disconnected"
        default: result.metrics.frameCount == 0 ? "no face frames" : "no clock sync yet"
        }
    }
}
