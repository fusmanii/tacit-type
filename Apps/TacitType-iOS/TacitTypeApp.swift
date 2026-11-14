import AVFoundation
import TacitKit
import SwiftUI
import os

@main
struct TacitTypeApp: App {
    @State private var model = CamModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.link)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}

/// App state from the spec's state table, plus the camera's single owner.
@MainActor
@Observable
final class CamModel: CaptureHost {
    enum Problem: Equatable {
        case noTrueDepth
        case cameraDenied
        case microphoneDenied
        case captureFailed(String)

        var message: String {
            switch self {
            case .noTrueDepth: "This iPhone has no TrueDepth camera. Tacit Type needs an iPhone with Face ID."
            case .cameraDenied: "Tacit Type needs the camera to read your face while your Mac is capturing. Turn it on in Settings."
            case .microphoneDenied: "Tacit Type needs the microphone to hear you while your Mac is capturing. Turn it on in Settings."
            case let .captureFailed(text): text
            }
        }

        var needsSettings: Bool { self == .cameraDenied || self == .microphoneDenied }
        var canRetry: Bool { if case .captureFailed = self { true } else { false } }
    }

    let link = LinkServer()
    private(set) var problem: Problem?
    private(set) var isCapturing = false
    private(set) var isPickerOpen = false
    private(set) var isCharging = false
    private(set) var tracking = CaptureController.Tracking()

    @ObservationIgnored private let capture = CaptureController()
    @ObservationIgnored private var active: (sessionId: UUID, link: PeerLink)?
    @ObservationIgnored private var safetyTimer: Task<Void, Never>?
    @ObservationIgnored private var savedBrightness: CGFloat?
    @ObservationIgnored private var wantsDim = false
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "session")

    init() {
        #if !targetEnvironment(simulator)
        // No TrueDepth in the Simulator. Let pairing and the link run there anyway.
        if !CaptureController.isSupported { problem = .noTrueDepth }
        #endif
        link.host = self
        capture.onTrackingChange = { [weak self] tracking in
            guard let self, isCapturing else { return }
            self.tracking = tracking
            link.broadcastStatus()
        }
        capture.onFailure = { [weak self] message in self?.captureFailed(message) }
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPower() }
        }
        refreshPower()
    }

    var deviceState: DeviceStatus.State {
        if problem != nil { return .error }
        if isCapturing { return .capturing }
        return link.pairedMacs.isEmpty ? .unpaired : .idle
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // iOS suspends listeners in the background, so bring them back on every return.
            link.start()
            refreshPower()
            Task { await refreshPermissions() }
        case .background:
            // ARKit can't run in the background. Stop cleanly instead of being cut off.
            if isCapturing { Task { await finishCapture(reason: "app left the foreground") } }
            restoreBrightness()
        default:
            break
        }
    }

    func retry() {
        guard problem?.canRetry == true else { return }
        problem = nil
        link.broadcastStatus()
    }

    // MARK: Permissions

    /// Asks once a Mac is paired, so the prompts don't slow down the first `start`.
    func refreshPermissions() async {
        guard problem == nil || problem?.needsSettings == true, !link.pairedMacs.isEmpty else { return }
        if problem == .noTrueDepth { return }

        var camera = AVCaptureDevice.authorizationStatus(for: .video)
        if camera == .notDetermined {
            camera = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        }
        var microphone = AVAudioApplication.shared.recordPermission
        if camera == .authorized, microphone == .undetermined {
            microphone = await AVAudioApplication.requestRecordPermission() ? .granted : .denied
        }

        let next: Problem? = if camera != .authorized { .cameraDenied }
            else if microphone == .denied { .microphoneDenied }
            else { nil }
        if next != problem {
            problem = next
            link.broadcastStatus()
        }
    }

    // MARK: CaptureHost

    func startCapture(_ request: StartCapture, from peer: PeerLink) -> ProtocolErrorMessage? {
        if let problem { return ProtocolErrorMessage(code: .captureFailed, message: problem.message) }
        if isPickerOpen { return ProtocolErrorMessage(code: .busy, message: "The lip vertex picker is using the camera.") }
        if let active, active.link !== peer {
            return ProtocolErrorMessage(code: .busy, message: "Another Mac is capturing.")
        }
        do {
            try capture.start(sessionId: request.sessionId, streams: request.streams, link: peer)
        } catch {
            return ProtocolErrorMessage(code: .captureFailed, message: String(describing: error))
        }
        active = (request.sessionId, peer)
        isCapturing = true
        armSafetyTimer()
        refreshPower()
        return nil
    }

    func stopCapture(_ request: StopCapture, from peer: PeerLink) async {
        guard let active, active.link === peer, active.sessionId == request.sessionId else { return }
        await finishCapture(reason: "stop")
    }

    func linkClosed(_ peer: PeerLink) {
        guard active?.link === peer else { return }
        Task { await finishCapture(reason: "Mac disconnected") }
    }

    private func finishCapture(reason: String) async {
        guard let active else { return }
        Self.log.info("Ending capture \(active.sessionId, privacy: .public): \(reason, privacy: .public)")
        self.active = nil
        isCapturing = false
        tracking = CaptureController.Tracking()
        safetyTimer?.cancel()
        safetyTimer = nil
        refreshPower()
        await capture.stop()
    }

    private func armSafetyTimer() {
        safetyTimer?.cancel()
        safetyTimer = Task {
            try? await Task.sleep(for: .seconds(Constants.maxCaptureDuration))
            guard !Task.isCancelled, isCapturing else { return }
            await finishCapture(reason: "\(Int(Constants.maxCaptureDuration)) s safety timeout")
            link.broadcastStatus()
        }
    }

    private func captureFailed(_ message: String) {
        guard let active else { return }
        let peer = active.link
        problem = .captureFailed(message)
        Task {
            await finishCapture(reason: message)
            peer.send(.error(ProtocolErrorMessage(code: .captureFailed, message: message)))
            link.broadcastStatus()
        }
    }

    // MARK: Lip vertex picker

    /// The picker runs its own ARKit session. Returns false while a Mac is capturing.
    func claimCameraForPicker() -> Bool {
        guard !isCapturing else { return false }
        isPickerOpen = true
        return true
    }

    func releaseCameraFromPicker() {
        isPickerOpen = false
    }

    // MARK: Dock mode

    /// The dock screen calls this as it appears and disappears.
    func setDockScreenVisible(_ visible: Bool) {
        wantsDim = visible
        refreshPower()
    }

    private func refreshPower() {
        let state = UIDevice.current.batteryState
        isCharging = state == .charging || state == .full
        UIApplication.shared.isIdleTimerDisabled = isCharging || isCapturing
        if wantsDim && isCharging { dim() } else { restoreBrightness() }
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    private func dim() {
        guard savedBrightness == nil, let screen else { return }
        savedBrightness = screen.brightness
        screen.brightness = 0.1
    }

    private func restoreBrightness() {
        guard let saved = savedBrightness else { return }
        savedBrightness = nil
        screen?.brightness = saved
    }
}
