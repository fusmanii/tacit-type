import CryptoKit
import Foundation
import Network
import Observation
import TacitKit
import os

/// Owns discovery, pairing and the connection to the iPhone app.
///
/// The Mac pairs with one iPhone at a time and connects to it whenever its main listener shows up
/// in the Bonjour browser. Drops are retried with `ReconnectBackoff` while the iPhone stays visible.
@MainActor
@Observable
final class DeviceManager {
    enum ConnectionState: Equatable {
        case notPaired
        case searching(deviceName: String)
        case connecting(deviceName: String)
        case connected(deviceName: String)
        /// The iPhone refused our key. It forgot this Mac while we weren't connected.
        case rejected(deviceName: String)
    }

    enum PairingState: Equatable {
        case idle
        case pairing(phoneId: UUID)
        case failed(String)
        case succeeded(deviceName: String)
    }

    struct PairedPhone: Codable, Equatable {
        var id: UUID
        var name: String
    }

    struct NearbyPhone: Identifiable, Equatable {
        var id: UUID
        var name: String
        var mainEndpoint: NWEndpoint?
        var pairingEndpoint: NWEndpoint?
        var isCompatible = true

        var canPair: Bool { pairingEndpoint != nil && isCompatible }
    }

    private(set) var connectionState: ConnectionState = .notPaired
    private(set) var pairingState: PairingState = .idle
    private(set) var paired: PairedPhone?
    private(set) var nearby: [NearbyPhone] = []
    private(set) var lastStatus: DeviceStatus?
    private(set) var clockEstimate: ClockSample?
    private(set) var isPathViable = true

    let macId: UUID
    /// Gets face batches, audio, status and errors while a session runs.
    @ObservationIgnored weak var captureReceiver: CaptureMessageReceiver?

    @ObservationIgnored private let keychain = KeychainStore.default
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var link: PeerLink?
    @ObservationIgnored private var pairingLink: PeerLink?
    /// An iPhone the user forgot while it wasn't connected. We keep its key until we've told it.
    @ObservationIgnored private var pendingForget: PairedPhone?
    @ObservationIgnored private var forgetLink: PeerLink?
    @ObservationIgnored private var forgetTimeouts = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var backoff = ReconnectBackoff()
    @ObservationIgnored private var burst = ClockSyncBurst()
    /// Over Bonjour a refused key shows up as a handshake timeout, so several in a row mean rejection.
    @ObservationIgnored private var consecutiveTimeouts = 0
    private static let timeoutsBeforeRejected = 3
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "net")
    private static let pairedKey = "pairedPhone"
    private static let pendingForgetKey = "pendingForgetPhone"
    private static let pairingTimeout: Duration = .seconds(6)

    init() {
        do {
            macId = try keychain.deviceId()
        } catch {
            Self.log.fault("No device id in Keychain: \(error). Pairing won't survive a relaunch.")
            macId = UUID()
        }
        paired = UserDefaults.standard.data(forKey: Self.pairedKey)
            .flatMap { try? JSONDecoder().decode(PairedPhone.self, from: $0) }
        if let paired, (try? keychain.linkKey(for: paired.id)) == nil {
            Self.log.error("Key for \(paired.name, privacy: .public) is missing. Treating it as unpaired.")
            self.paired = nil
            savePaired()
        }
        pendingForget = UserDefaults.standard.data(forKey: Self.pendingForgetKey)
            .flatMap { try? JSONDecoder().decode(PairedPhone.self, from: $0) }
        connectionState = paired.map { .searching(deviceName: $0.name) } ?? .notPaired
        startBrowsing()
    }

    var statusLine: String {
        switch connectionState {
        case .notPaired: "No iPhone paired"
        case let .searching(name): "\(name) · Open Tacit Type on your iPhone"
        case let .connecting(name): "Connecting to \(name)…"
        case let .connected(name): isPathViable ? "\(name) connected" : "\(name) · connection interrupted"
        case let .rejected(name): "\(name) no longer recognises this Mac"
        }
    }

    var isConnected: Bool {
        if case .connected = connectionState { true } else { false }
    }

    // MARK: Discovery

    private func startBrowsing() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Constants.bonjourServiceType, domain: nil),
                                using: LinkParameters.browser())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard case let .failed(error) = state, let self, let browser, self.browser === browser else { return }
                Self.log.error("Browser failed: \(error). Restarting.")
                browser.cancel()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    self.startBrowsing()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var phones: [UUID: NearbyPhone] = [:]
        for result in results {
            guard case let .bonjour(txt) = result.metadata, let advert = ServiceAdvert(txtRecord: txt) else { continue }
            var phone = phones[advert.deviceId] ?? NearbyPhone(id: advert.deviceId, name: advert.name)
            phone.name = advert.name
            phone.isCompatible = phone.isCompatible && advert.protocolVersion == Constants.protocolVersion
            if advert.isPairing { phone.pairingEndpoint = result.endpoint } else { phone.mainEndpoint = result.endpoint }
            phones[advert.deviceId] = phone
        }

        let wasVisible = paired.flatMap { id in nearby.first { $0.id == id.id }?.mainEndpoint } != nil
        nearby = phones.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let isVisible = mainEndpoint(for: paired?.id) != nil

        if isVisible, !wasVisible {
            // It just appeared (app opened). Connect now instead of waiting out a long backoff,
            // and give a rejected key one more try in case the rejection was a flaky network.
            backoff.reset()
            consecutiveTimeouts = 0
            if case let .rejected(name) = connectionState { connectionState = .searching(deviceName: name) }
            retryTask?.cancel()
            retryTask = nil
        }
        evaluateConnection()
        deliverPendingForget()
    }

    private func mainEndpoint(for id: UUID?) -> NWEndpoint? {
        guard let id else { return nil }
        return nearby.first { $0.id == id && $0.isCompatible }?.mainEndpoint
    }

    // MARK: Connection

    private func evaluateConnection() {
        guard let paired else {
            connectionState = .notPaired
            return
        }
        if case .rejected = connectionState { return }
        guard link == nil, retryTask == nil else { return }
        guard let endpoint = mainEndpoint(for: paired.id) else {
            connectionState = .searching(deviceName: paired.name)
            return
        }
        let key: Data
        do {
            guard let stored = try keychain.linkKey(for: paired.id) else {
                Self.log.error("Key for \(paired.name) vanished from the Keychain")
                forgetLocally()
                return
            }
            key = stored
        } catch {
            Self.log.error("Couldn't read the key for \(paired.name): \(error)")
            return
        }

        let link = PeerLink(to: endpoint, using: LinkParameters.client(key: key, identity: .paired(macId: macId)))
        self.link = link
        connectionState = .connecting(deviceName: paired.name)
        Self.log.info("Connecting to \(paired.name, privacy: .public)")
        link.start()
        Task {
            for await event in link.events {
                handle(event, on: link)
            }
        }
    }

    private func handle(_ event: PeerLink.Event, on link: PeerLink) {
        guard self.link === link, let paired else { return }
        switch event {
        case .ready:
            link.send(.hello(hello))
        case let .message(message):
            handle(message, on: link, paired: paired)
        case let .viabilityChanged(viable):
            isPathViable = viable
        case let .closed(reason):
            self.link = nil
            captureReceiver?.linkDropped()
            stopClockSync()
            lastStatus = nil
            isPathViable = true
            if reason == .timedOut { consecutiveTimeouts += 1 }
            if reason == .authenticationFailed || consecutiveTimeouts >= Self.timeoutsBeforeRejected {
                Self.log.error("\(paired.name, privacy: .public) rejected our key (\(String(describing: reason), privacy: .public))")
                connectionState = .rejected(deviceName: paired.name)
            } else {
                Self.log.info("Link to \(paired.name, privacy: .public) closed: \(String(describing: reason), privacy: .public)")
                scheduleRetry()
            }
        }
    }

    private func handle(_ message: Message, on link: PeerLink, paired: PairedPhone) {
        switch message {
        case let .hello(hello):
            guard hello.deviceId == paired.id else {
                Self.log.error("Expected \(paired.id), got hello from \(hello.deviceId)")
                link.cancel()
                return
            }
            if hello.deviceName != paired.name {
                self.paired?.name = hello.deviceName
                savePaired()
            }
            connectionState = .connected(deviceName: hello.deviceName)
            backoff.reset()
            consecutiveTimeouts = 0
            Self.log.notice("Connected to \(hello.deviceName, privacy: .public) (\(hello.deviceModel, privacy: .public), app \(hello.appVersion, privacy: .public))")
            startClockSync(on: link)
        case .faceBatch, .audioChunk:
            captureReceiver?.receive(message)
        case let .status(status):
            lastStatus = status
            captureReceiver?.receive(message)
            if status.thermalState == .serious || status.thermalState == .critical {
                Self.log.warning("iPhone thermal state is \(status.thermalState.rawValue)")
            }
        case let .clockPong(pong):
            guard let sample = ClockSample(pong: pong, receivedAt: HostClock.now()) else { return }
            burst.add(sample)
            if burst.isComplete {
                clockEstimate = burst.best
                if let best = burst.best {
                    Self.log.debug("Clock offset \(best.offset, format: .fixed(precision: 4)) s, RTT \(best.roundTrip * 1000, format: .fixed(precision: 1)) ms")
                }
            } else {
                sendPing(on: link)
            }
        case .forget:
            Self.log.notice("\(paired.name) forgot this Mac")
            forgetLocally()
            link.cancel()
        case let .error(error):
            Self.log.error("iPhone reported \(error.code.rawValue): \(error.message)")
            captureReceiver?.receive(message)
        default:
            Self.log.notice("Ignoring \(String(describing: message.type)) from iPhone")
        }
    }

    private func scheduleRetry() {
        guard let paired, retryTask == nil else { return }
        connectionState = .searching(deviceName: paired.name)
        let delay = backoff.next()
        retryTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            retryTask = nil
            evaluateConnection()
        }
    }

    /// Sends on the connected link. False if the iPhone isn't connected.
    func send(_ message: Message) -> Bool {
        guard let link, isConnected else { return false }
        link.send(message)
        return true
    }

    // MARK: Clock sync

    private func startClockSync(on link: PeerLink) {
        stopClockSync()
        clockTask = Task {
            while !Task.isCancelled {
                burst = ClockSyncBurst()
                sendPing(on: link)
                try? await Task.sleep(for: ClockSyncBurst.interval)
            }
        }
    }

    private func stopClockSync() {
        clockTask?.cancel()
        clockTask = nil
    }

    private func sendPing(on link: PeerLink) {
        link.send(.clockPing(ClockSync(t0: HostClock.now())))
    }

    // MARK: Pairing

    func pair(with phoneId: UUID, code: String) {
        guard Pairing.isValidCode(code) else {
            pairingState = .failed("Type the 6-digit code shown on your iPhone.")
            return
        }
        guard let phone = nearby.first(where: { $0.id == phoneId }), let endpoint = phone.pairingEndpoint else {
            pairingState = .failed("That iPhone isn't showing a pairing code anymore.")
            return
        }
        pairingLink?.cancel()
        pairingState = .pairing(phoneId: phoneId)

        let key = Pairing.pairingKey(code: code, iphoneId: phoneId)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let link = PeerLink(to: endpoint, using: LinkParameters.client(key: key.data, identity: .pairing))
        pairingLink = link
        link.start(timeout: Self.pairingTimeout)

        Task {
            var phoneName = phone.name
            for await event in link.events {
                guard pairingLink === link else { break }
                switch event {
                case .ready:
                    link.send(.hello(hello))
                    link.send(.pairRequest(PairRequest(publicKey: ephemeral.publicKey.rawRepresentation)))
                case let .message(.hello(hello)):
                    guard hello.deviceId == phoneId else {
                        pairingState = .failed("A different iPhone answered. Try again.")
                        link.cancel()
                        break
                    }
                    phoneName = hello.deviceName
                case let .message(.pairAccept(accept)):
                    do {
                        let longTerm = try Pairing.longTermKey(privateKey: ephemeral, peerPublicKey: accept.publicKey,
                                                               iphoneId: phoneId, macId: macId)
                        try completePairing(with: PairedPhone(id: phoneId, name: phoneName), key: longTerm.data)
                    } catch {
                        Self.log.error("Pairing failed: \(error)")
                        pairingState = .failed("Pairing failed: \(error.localizedDescription)")
                    }
                    link.cancel()
                case let .message(.error(error)):
                    pairingState = .failed(error.message)
                case .closed(.authenticationFailed), .closed(.timedOut):
                    // Over Bonjour a wrong code usually shows up as a timeout, not a TLS error.
                    if case .pairing = pairingState {
                        pairingState = .failed("That code didn't match. Check the code on your iPhone and try again.")
                    }
                case .closed:
                    if case .pairing = pairingState {
                        pairingState = .failed("Lost the connection to the iPhone. Try again.")
                    }
                case .message, .viabilityChanged:
                    break
                }
            }
            if pairingLink === link { pairingLink = nil }
        }
    }

    func resetPairingState() {
        pairingLink?.cancel()
        pairingLink = nil
        pairingState = .idle
    }

    private func completePairing(with phone: PairedPhone, key: Data) throws {
        if let old = paired, old.id != phone.id { forgetPairedPhone() }
        try keychain.setLinkKey(key, for: phone.id)
        if pendingForget?.id == phone.id {
            forgetLink?.cancel()
            forgetLink = nil
            setPendingForget(nil)
        }
        paired = phone
        savePaired()
        Self.log.notice("Paired with \(phone.name, privacy: .public)")

        // Drop any link that used the old key and connect with the new one right away.
        link?.cancel()
        link = nil
        retryTask?.cancel()
        retryTask = nil
        backoff.reset()
        consecutiveTimeouts = 0
        connectionState = .searching(deviceName: phone.name)
        pairingState = .succeeded(deviceName: phone.name)
        evaluateConnection()
    }

    // MARK: Forget

    /// Deletes our key and tells the iPhone to delete its key.
    ///
    /// If the iPhone isn't connected right now, the key is kept as a pending forget and used once,
    /// the next time the iPhone shows up, to deliver `forget`. Without that, the iPhone would stay
    /// paired to a Mac that can no longer reach it.
    func forgetPairedPhone() {
        guard let phone = paired else { return }
        if let link, isConnected {
            Self.log.notice("Forgetting \(phone.name, privacy: .public) and telling it now")
            link.send(.forget(Forget()), thenClose: .cancelled)
            forgetLocally()
        } else {
            Self.log.notice("Forgetting \(phone.name, privacy: .public). It isn't connected, so it'll be told when it appears.")
            link?.cancel()
            setPendingForget(phone)
            paired = nil
            savePaired()
            resetConnection()
            deliverPendingForget()
        }
    }

    private func deliverPendingForget() {
        guard let phone = pendingForget, forgetLink == nil, let endpoint = mainEndpoint(for: phone.id) else { return }
        guard let key = try? keychain.linkKey(for: phone.id) else {
            setPendingForget(nil)
            return
        }
        let link = PeerLink(to: endpoint, using: LinkParameters.client(key: key, identity: .paired(macId: macId)))
        forgetLink = link
        link.start()
        Task {
            var sent = false
            for await event in link.events {
                switch event {
                case .ready:
                    link.send(.hello(hello))
                case .message(.hello):
                    // The iPhone only accepts messages after hello.
                    link.send(.forget(Forget()), thenClose: .cancelled)
                    sent = true
                case let .closed(reason):
                    forgetLink = nil
                    let iphoneAlreadyForgot = reason == .authenticationFailed
                    if reason == .timedOut { forgetTimeouts += 1 }
                    if sent || iphoneAlreadyForgot || forgetTimeouts >= Self.timeoutsBeforeRejected {
                        Self.log.notice("Pending forget for \(phone.name, privacy: .public) done (\(String(describing: reason), privacy: .public))")
                        if pendingForget == phone {
                            if paired?.id != phone.id { try? keychain.deleteLinkKey(for: phone.id) }
                            setPendingForget(nil)
                        }
                    }
                default:
                    break
                }
            }
        }
    }

    private func setPendingForget(_ phone: PairedPhone?) {
        pendingForget = phone
        forgetTimeouts = 0
        UserDefaults.standard.set(phone.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.pendingForgetKey)
    }

    private func forgetLocally() {
        if let paired {
            do {
                try keychain.deleteLinkKey(for: paired.id)
            } catch {
                Self.log.error("Couldn't delete key for \(paired.name): \(error)")
            }
        }
        paired = nil
        savePaired()
        resetConnection()
    }

    private func resetConnection() {
        link = nil
        retryTask?.cancel()
        retryTask = nil
        stopClockSync()
        lastStatus = nil
        clockEstimate = nil
        connectionState = .notPaired
    }

    private func savePaired() {
        UserDefaults.standard.set(paired.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.pairedKey)
    }

    // MARK: Hello

    private var hello: Hello {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return Hello(deviceId: macId, deviceName: Host.current().localizedName ?? "Mac",
                     deviceModel: Self.modelIdentifier, appVersion: version)
    }

    private static let modelIdentifier: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
}
