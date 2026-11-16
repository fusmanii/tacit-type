import AppKit
import Foundation
import Observation
import TacitKit
import os

/// Starts, health-checks and restarts the lip-reading sidecar (`python -m silentml.serve`).
///
/// The sidecar exits when its stdin closes. This class holds the write end of that pipe for the
/// sidecar's whole life, so if the app dies for any reason the sidecar follows it.
@MainActor
@Observable
final class ModelSidecar {
    enum State: Equatable {
        /// The Python environment or a checkpoint is missing. The message says what to fix.
        case notConfigured(String)
        case starting
        case ready
        /// Exited unexpectedly. A restart is scheduled.
        case crashed(Int32)
        /// Gave up: a setup problem, or too many crashes. Restart from Settings.
        case failed(String)
        case stopped
    }

    static let startupTimeout: Duration = .seconds(120)
    static let transcribeTimeout: Duration = .seconds(4)
    static let maxCrashes = 3
    static let crashWindow: TimeInterval = 300
    static let maxLogBytes = 1_000_000
    /// `silentml.serve` exits with this for a problem a restart won't fix.
    static let setupFailedExitCode: Int32 = 2

    private(set) var state: State = .stopped
    private(set) var health: SidecarReply.Health?
    private(set) var startedAt: Date?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdin: Pipe?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var crashTimes: [Date] = []
    @ObservationIgnored private var backoff = ReconnectBackoff()
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private let client = SidecarClient(socketPath: SilentDictationSettings.socketURL.path)
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "silent")

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    var isReady: Bool { state == .ready }

    var python: URL? { SilentDictationSettings.mlFolder?.appending(path: ".venv/bin/python") }

    /// Why the sidecar can't start, or nil when it can.
    func configurationProblem() -> String? {
        guard let folder = SilentDictationSettings.mlFolder else {
            return "Choose the repo's ml folder in Settings → Silent Dictation."
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appending(path: "silentml/serve.py").path) else {
            return "\(folder.path) has no silentml/serve.py."
        }
        guard let python, fm.isExecutableFile(atPath: python.path) else {
            return "No Python environment in \(folder.path). Run `make ml-env`."
        }
        if let checkpoint = SilentDictationSettings.checkpoint, !fm.fileExists(atPath: checkpoint.path) {
            return "The checkpoint \(checkpoint.lastPathComponent) is missing."
        }
        guard Array(SilentDictationSettings.socketURL.path.utf8).count <= SidecarProtocol.maxSocketPathBytes else {
            return "The socket path is too long for macOS."
        }
        return nil
    }

    // MARK: Lifecycle

    func start() {
        guard process == nil else { return }
        restartTask?.cancel()
        if let problem = configurationProblem() {
            state = .notConfigured(problem)
            return
        }
        guard let folder = SilentDictationSettings.mlFolder, let python else { return }
        var arguments = ["-m", "silentml.serve", "--socket", SilentDictationSettings.socketURL.path,
                         "--model", SilentDictationSettings.model, "--beam", "\(SilentDictationSettings.beam)"]
        if let checkpoint = SilentDictationSettings.checkpoint { arguments += ["--checkpoint", checkpoint.path] }

        let process = Process()
        process.executableURL = python
        process.arguments = arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let stdin = Pipe()
        process.standardInput = stdin
        do {
            let log = try openLog()
            process.standardOutput = log
            process.standardError = log
        } catch {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            Task { @MainActor in self?.exited(finished, status: status, signalled: reason == .uncaughtSignal) }
        }
        do {
            try process.run()
        } catch {
            state = .failed("Couldn't start Python: \(error.localizedDescription)")
            return
        }
        self.process = process
        self.stdin = stdin
        stopping = false
        health = nil
        startedAt = .now
        state = .starting
        Self.log.notice("Sidecar started, pid \(process.processIdentifier)")
        monitor?.cancel()
        monitor = Task { await watch(process) }
    }

    func stop() {
        stopping = true
        restartTask?.cancel()
        monitor?.cancel()
        // Closing stdin asks the sidecar to exit. terminate() makes sure.
        try? stdin?.fileHandleForWriting.close()
        process?.terminate()
        process = nil
        stdin = nil
        health = nil
        state = .stopped
    }

    /// From Settings. Also clears the crash count, so a fixed setup gets a fresh start.
    func restart() {
        stop()
        crashTimes.removeAll()
        backoff.reset()
        start()
    }

    private func exited(_ finished: Process, status: Int32, signalled: Bool) {
        guard finished === process else { return }
        process = nil
        stdin = nil
        health = nil
        monitor?.cancel()
        if stopping { return }
        Self.log.error("Sidecar exited with \(signalled ? "signal" : "status", privacy: .public) \(status)")
        if !signalled, status == Self.setupFailedExitCode {
            state = .failed(lastLogLine() ?? "The sidecar couldn't load its model.")
            return
        }
        let now = Date.now
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < Self.crashWindow } + [now]
        if crashTimes.count >= Self.maxCrashes {
            state = .failed("The sidecar crashed \(crashTimes.count) times in 5 minutes. \(lastLogLine() ?? "")")
            return
        }
        state = .crashed(status)
        let delay = backoff.next()
        restartTask = Task {
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { start() }
        }
    }

    /// Polls `health`: every 2 s while loading, every 30 s once ready. Three missed polls in a row
    /// while ready means the sidecar is stuck, so it is killed and the crash path restarts it.
    private func watch(_ process: Process) async {
        var missed = 0
        let startedAt = ContinuousClock.now
        while !Task.isCancelled, process.isRunning {
            let ready = state == .ready
            do {
                let reply = try await client.send(.health(id: takeId()), timeout: .seconds(5))
                missed = 0
                if let health = reply.health {
                    self.health = health
                    if health.protocolVersion != Constants.sidecarProtocolVersion {
                        state = .failed("The sidecar speaks protocol \(health.protocolVersion), this app \(Constants.sidecarProtocolVersion).")
                        stopping = true
                        process.terminate()
                        return
                    }
                    if health.state == .ready, state != .ready {
                        state = .ready
                        backoff.reset()
                        Self.log.notice("Sidecar ready in \((ContinuousClock.now - startedAt).seconds, format: .fixed(precision: 1)) s")
                    }
                }
            } catch {
                if ready {
                    missed += 1
                    if missed >= 3 {
                        Self.log.error("Sidecar stopped answering. Restarting it.")
                        process.terminate()
                        return
                    }
                } else if ContinuousClock.now - startedAt > Self.startupTimeout {
                    stopping = true
                    process.terminate()
                    state = .failed("The sidecar didn't get ready within 2 minutes. \(lastLogLine() ?? "")")
                    return
                }
            }
            try? await Task.sleep(for: state == .ready ? .seconds(30) : .seconds(2))
        }
    }

    private func takeId() -> Int {
        defer { nextId += 1 }
        return nextId
    }

    // MARK: Requests

    enum TranscribeError: Error, LocalizedError {
        case notReady
        case sidecar(SidecarReply.Failure)
        case badReply

        var errorDescription: String? {
            switch self {
            case .notReady: "The lip-reading model isn't ready"
            case let .sidecar(failure): failure.message
            case .badReply: "The sidecar sent an unexpected reply"
            }
        }
    }

    func transcribe(session: URL, start: Double?, end: Double?) async throws -> SidecarReply.Transcript {
        guard isReady else { throw TranscribeError.notReady }
        let reply = try await client.send(.transcribe(id: takeId(), session: session, start: start, end: end),
                                          timeout: Self.transcribeTimeout)
        if let error = reply.error {
            throw error.code == .notReady ? TranscribeError.notReady : TranscribeError.sidecar(error)
        }
        guard let transcript = reply.transcript, !transcript.hypotheses.isEmpty else { throw TranscribeError.badReply }
        return transcript
    }

    // MARK: Log

    /// Appends to `sidecar.log`. Past `maxLogBytes` the old log moves to `sidecar.log.1` first.
    private func openLog() throws -> FileHandle {
        let url = SilentDictationSettings.logURL
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > Self.maxLogBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(Data("--- \(Date.now.formatted(.iso8601)) starting\n".utf8))
        return handle
    }

    /// The last `count` lines of the log, oldest first.
    func logTail(_ count: Int = 20) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: SilentDictationSettings.logURL) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        // PyAV and OpenCV both bundle libavdevice, and the Objective-C runtime warns about it on every start.
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("objc[") }
        return Array(lines.suffix(count))
    }

    private func lastLogLine() -> String? {
        logTail(5).last { !$0.hasPrefix("---") }
    }
}
