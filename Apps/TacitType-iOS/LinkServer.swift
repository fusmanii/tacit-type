import CryptoKit
import Network
import Observation
import TacitKit
import UIKit
import os

/// What the link needs from the app to serve `start`, `stop` and `status`.
@MainActor
protocol CaptureHost: AnyObject {
    var deviceState: DeviceStatus.State { get }
    var tracking: CaptureController.Tracking { get }
    /// Starts capturing for `link`. Returns the error to send back if it can't.
    func startCapture(_ request: StartCapture, from link: PeerLink) -> ProtocolErrorMessage?
    /// Returns once the last batch for the session has been queued on the link.
    func stopCapture(_ request: StopCapture, from link: PeerLink) async
    func linkClosed(_ link: PeerLink)
}

struct PairedMac: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
}

/// The iPhone end of the link. Advertises over Bonjour, pairs new Macs and serves paired ones.
///
/// Two listeners share the `_tacittype._tcp` service type. The main listener holds one PSK per paired
/// Mac and is rebuilt whenever that set changes. The pairing listener exists only while a code is on
/// screen, holds only the code-derived PSK, and accepts nothing but `hello` + `pairRequest`.
@MainActor
@Observable
final class LinkServer {
    private(set) var pairedMacs: [PairedMac]
    /// Non-nil while the pairing listener is up and the code is on screen.
    private(set) var pairingCode: String?
    private(set) var connectedMacIds: Set<UUID> = []

    let deviceId: UUID
    @ObservationIgnored weak var host: CaptureHost?

    @ObservationIgnored private let keychain = KeychainStore.default
    @ObservationIgnored private var mainListener: NWListener?
    @ObservationIgnored private var pairingListener: NWListener?
    @ObservationIgnored private var sessions: [ObjectIdentifier: Session] = [:]
    @ObservationIgnored private var failedPairingAttempts = 0
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "net")
    private static let pairedMacsKey = "pairedMacs"

    init() {
        do {
            deviceId = try keychain.deviceId()
        } catch {
            Self.log.fault("No device id in Keychain: \(error). Pairings won't survive a relaunch.")
            deviceId = UUID()
        }
        pairedMacs = UserDefaults.standard.data(forKey: Self.pairedMacsKey)
            .flatMap { try? JSONDecoder().decode([PairedMac].self, from: $0) } ?? []
        // Drop any Mac whose key went missing, so it can pair again.
        pairedMacs.removeAll { (try? keychain.linkKey(for: $0.id)) == nil }
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// Call on launch and whenever the app comes back to the foreground.
    func start() {
        if mainListener == nil || mainListener?.state != .ready { restartMainListener() }
        if pairedMacs.isEmpty, pairingCode == nil {
            openPairing()
        } else if pairingCode != nil, pairingListener?.state != .ready {
            restartPairingListener()
        }
    }

    func openPairing() {
        pairingCode = Pairing.randomCode()
        failedPairingAttempts = 0
        restartPairingListener()
    }

    /// Only meaningful once a Mac is paired. With none, the code stays up.
    func closePairing() {
        guard !pairedMacs.isEmpty else { return }
        pairingCode = nil
        pairingListener?.cancel()
        pairingListener = nil
    }

    func forget(_ mac: PairedMac) {
        for session in sessions.values where session.macId == mac.id {
            session.link.send(.forget(Forget()), thenClose: .cancelled)
        }
        removeMac(mac.id)
    }

    // MARK: Listeners

    private var displayName: String { UIDevice.current.name }

    private func restartMainListener() {
        mainListener?.cancel()
        mainListener = nil

        var keys: [PSKIdentity: Data] = [:]
        for mac in pairedMacs {
            if let key = try? keychain.linkKey(for: mac.id) { keys[.paired(macId: mac.id)] = key }
        }
        guard !keys.isEmpty else { return }

        do {
            let listener = try NWListener(using: LinkParameters.server(keys: keys))
            listener.service = ServiceAdvert(deviceId: deviceId, name: displayName, isPairing: false).service
            configure(listener, kind: .main)
            mainListener = listener
        } catch {
            Self.log.error("Main listener failed to start: \(error)")
        }
    }

    private func restartPairingListener() {
        pairingListener?.cancel()
        pairingListener = nil
        guard let pairingCode else { return }

        let key = Pairing.pairingKey(code: pairingCode, iphoneId: deviceId).data
        do {
            let listener = try NWListener(using: LinkParameters.server(keys: [.pairing: key]))
            listener.service = ServiceAdvert(deviceId: deviceId, name: displayName, isPairing: true).service
            configure(listener, kind: .pairing)
            pairingListener = listener
        } catch {
            Self.log.error("Pairing listener failed to start: \(error)")
        }
    }

    private func configure(_ listener: NWListener, kind: Session.Kind) {
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection, kind: kind) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    Self.log.info("\(String(describing: kind)) listener ready on port \(listener.port?.debugDescription ?? "?")")
                case let .failed(error):
                    Self.log.error("\(String(describing: kind)) listener failed: \(error). Restarting.")
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        self.restart(kind, ifStill: listener)
                    }
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
    }

    private func restart(_ kind: Session.Kind, ifStill listener: NWListener) {
        switch kind {
        case .main where mainListener === listener: restartMainListener()
        case .pairing where pairingListener === listener: restartPairingListener()
        default: break
        }
    }

    // MARK: Sessions

    private func accept(_ connection: NWConnection, kind: Session.Kind) {
        let session = Session(link: PeerLink(connection: connection), kind: kind)
        let key = ObjectIdentifier(session)
        sessions[key] = session
        session.link.start()
        Task {
            for await event in session.link.events {
                handle(event, in: session)
            }
            sessions[key] = nil
            refreshConnected()
            host?.linkClosed(session.link)
        }
    }

    private func handle(_ event: PeerLink.Event, in session: Session) {
        switch event {
        case .ready:
            session.link.send(.hello(hello))
        case let .message(message):
            switch session.kind {
            case .main: handleMain(message, in: session)
            case .pairing: handlePairing(message, in: session)
            }
        case .viabilityChanged:
            break
        case let .closed(reason):
            if session.kind == .pairing, reason == .authenticationFailed, pairingCode != nil {
                failedPairingAttempts += 1
                Self.log.notice("Wrong pairing code (\(self.failedPairingAttempts) of \(Pairing.maxFailedAttempts))")
                if failedPairingAttempts >= Pairing.maxFailedAttempts { openPairing() }
            }
        }
    }

    private func handleMain(_ message: Message, in session: Session) {
        if case let .hello(hello) = message {
            guard let index = pairedMacs.firstIndex(where: { $0.id == hello.deviceId }) else {
                reject(session, "This Mac isn't paired with this iPhone.")
                return
            }
            // A Mac that reconnects replaces its old, probably dead, session.
            for other in sessions.values where other !== session && other.macId == hello.deviceId {
                other.link.cancel()
            }
            session.macId = hello.deviceId
            if pairedMacs[index].name != hello.deviceName {
                pairedMacs[index].name = hello.deviceName
                savePairedMacs()
            }
            refreshConnected()
            session.link.send(.status(status))
            return
        }

        guard let macId = session.macId else {
            reject(session, "Send hello first.")
            return
        }
        switch message {
        case let .clockPing(ping):
            let received = HostClock.now()
            session.link.send(.clockPong(ClockSync(t0: ping.t0, t1: received, t2: HostClock.now())))
        case .forget:
            Self.log.notice("Mac \(macId) asked to be forgotten")
            removeMac(macId)
            session.link.cancel()
        case let .error(error):
            Self.log.error("Mac reported \(error.code.rawValue): \(error.message)")
        case let .start(request):
            if let error = host?.startCapture(request, from: session.link) {
                Self.log.error("Refused start \(request.sessionId, privacy: .public): \(error.message, privacy: .public)")
                session.link.send(.error(error))
            }
            broadcastStatus()
        case let .stop(request):
            // The status that follows the last batch tells the Mac the session is complete.
            Task {
                await host?.stopCapture(request, from: session.link)
                broadcastStatus()
            }
        default:
            Self.log.notice("Ignoring \(String(describing: message.type)) from Mac")
        }
    }

    /// Sends the current status to every connected Mac.
    func broadcastStatus() {
        let status = status
        for session in sessions.values where session.kind == .main && session.macId != nil {
            session.link.send(.status(status))
        }
    }

    private func handlePairing(_ message: Message, in session: Session) {
        switch message {
        case let .hello(hello):
            session.macId = hello.deviceId
            session.macName = hello.deviceName
        case let .pairRequest(request):
            guard let macId = session.macId else {
                reject(session, "Send hello first.")
                return
            }
            do {
                let ours = Curve25519.KeyAgreement.PrivateKey()
                let key = try Pairing.longTermKey(privateKey: ours, peerPublicKey: request.publicKey,
                                                  iphoneId: deviceId, macId: macId)
                try keychain.setLinkKey(key.data, for: macId)
                pairedMacs.removeAll { $0.id == macId }
                pairedMacs.append(PairedMac(id: macId, name: session.macName ?? "Mac"))
                savePairedMacs()
                Self.log.notice("Paired with \(session.macName ?? "Mac") \(macId)")

                session.link.send(.pairAccept(PairAccept(publicKey: ours.publicKey.rawRepresentation)), thenClose: .cancelled)
                closePairing()
                restartMainListener()
            } catch {
                Self.log.error("Pairing failed: \(error)")
                reject(session, "Pairing failed on the iPhone.")
            }
        default:
            reject(session, "Only pairing is allowed here.")
        }
    }

    private func reject(_ session: Session, _ text: String) {
        session.link.send(.error(ProtocolErrorMessage(code: .notPaired, message: text)), thenClose: .cancelled)
    }

    private func removeMac(_ id: UUID) {
        do {
            try keychain.deleteLinkKey(for: id)
        } catch {
            Self.log.error("Couldn't delete key for \(id): \(error)")
        }
        pairedMacs.removeAll { $0.id == id }
        savePairedMacs()
        restartMainListener()
        if pairedMacs.isEmpty { openPairing() }
    }

    private func refreshConnected() {
        connectedMacIds = Set(sessions.values.filter { $0.kind == .main }.compactMap(\.macId))
    }

    private func savePairedMacs() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pairedMacs), forKey: Self.pairedMacsKey)
    }

    // MARK: Messages

    private var hello: Hello {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return Hello(deviceId: deviceId, deviceName: displayName, deviceModel: Self.modelIdentifier,
                     appVersion: version, capabilities: ["face", "audio"])
    }

    private var status: DeviceStatus {
        let device = UIDevice.current
        let thermal: DeviceStatus.ThermalState = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
        let tracking = host?.tracking ?? CaptureController.Tracking()
        return DeviceStatus(state: host?.deviceState ?? .idle, trackingState: tracking.state, faceDetected: tracking.faceDetected,
                            thermalState: thermal, batteryLevel: device.batteryLevel,
                            isCharging: device.batteryState == .charging || device.batteryState == .full)
    }

    private static let modelIdentifier: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()
}

/// One accepted connection and what we know about the Mac on the other end.
@MainActor
private final class Session {
    enum Kind { case main, pairing }

    let link: PeerLink
    let kind: Kind
    var macId: UUID?
    var macName: String?

    init(link: PeerLink, kind: Kind) {
        self.link = link
        self.kind = kind
    }
}
