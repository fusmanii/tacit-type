import CryptoKit
import Foundation
import Network
import os
import Testing
@testable import TacitKit

private let iphoneId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
private let macId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

@Suite("Pairing crypto")
struct PairingCryptoTests {
    @Test func codesAreSixDigits() {
        for _ in 0 ..< 200 {
            #expect(Pairing.isValidCode(Pairing.randomCode()))
        }
        #expect(!Pairing.isValidCode("12345"))
        #expect(!Pairing.isValidCode("12345a"))
        #expect(!Pairing.isValidCode("１２３４５６"))
    }

    @Test func pairingKeyIsDeterministicAndBoundToCodeAndPhone() {
        let key = Pairing.pairingKey(code: "123456", iphoneId: iphoneId).data
        #expect(key.count == 32)
        #expect(key == Pairing.pairingKey(code: "123456", iphoneId: iphoneId).data)
        #expect(key != Pairing.pairingKey(code: "123457", iphoneId: iphoneId).data)
        #expect(key != Pairing.pairingKey(code: "123456", iphoneId: macId).data)
    }

    @Test func pairingKeyMatchesRFC5869Construction() {
        // HKDF-SHA256 computed by hand, so a CryptoKit change can't silently break pairing between versions.
        let prk = HMAC<SHA256>.authenticationCode(for: Data("123456".utf8), using: SymmetricKey(data: iphoneId.bytes))
        let okm = HMAC<SHA256>.authenticationCode(for: Data("tacittype-pair-v1".utf8) + [0x01], using: SymmetricKey(data: Data(prk)))
        #expect(Pairing.pairingKey(code: "123456", iphoneId: iphoneId).data == Data(okm))
    }

    @Test func bothSidesDeriveTheSameLongTermKey() throws {
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let onMac = try Pairing.longTermKey(privateKey: mac, peerPublicKey: phone.publicKey.rawRepresentation,
                                            iphoneId: iphoneId, macId: macId)
        let onPhone = try Pairing.longTermKey(privateKey: phone, peerPublicKey: mac.publicKey.rawRepresentation,
                                              iphoneId: iphoneId, macId: macId)
        #expect(onMac == onPhone)
        #expect(onMac.data.count == 32)
    }

    @Test func rejectsMalformedPublicKey() {
        #expect(throws: (any Error).self) {
            try Pairing.longTermKey(privateKey: .init(), peerPublicKey: Data([1, 2, 3]), iphoneId: iphoneId, macId: macId)
        }
    }

    @Test func identitiesAreDistinct() {
        #expect(PSKIdentity.pairing.data != PSKIdentity.paired(macId: macId).data)
        #expect(PSKIdentity.paired(macId: macId).data != PSKIdentity.paired(macId: iphoneId).data)
    }
}

@Suite("Link helpers")
struct LinkHelperTests {
    @Test func advertRoundTripsThroughTXT() {
        for pairing in [false, true] {
            let advert = ServiceAdvert(deviceId: iphoneId, name: "Faisal's iPhone", isPairing: pairing)
            #expect(ServiceAdvert(txtRecord: advert.txtRecord) == advert)
        }
        #expect(ServiceAdvert(txtRecord: NWTXTRecord(["name": "x"])) == nil)
    }

    @Test func pairingAdvertHasDistinctServiceName() {
        let main = ServiceAdvert(deviceId: iphoneId, name: "iPhone", isPairing: false)
        let pairing = ServiceAdvert(deviceId: iphoneId, name: "iPhone", isPairing: true)
        #expect(main.serviceName != pairing.serviceName)
    }

    @Test func backoffFollowsSpecAndCaps() {
        var backoff = ReconnectBackoff()
        let delays = (0 ..< 6).map { _ in backoff.next() }
        #expect(delays == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5), .seconds(5), .seconds(5)])
        backoff.reset()
        #expect(backoff.next() == .milliseconds(500))
    }

    @Test func clockSampleRecoversOffset() {
        // Ponger is 100 s ahead, each leg takes 4 ms, ponger turns around in 1 ms.
        let sample = ClockSample(t0: 10.000, t1: 110.004, t2: 110.005, t3: 10.009)
        #expect(abs(sample.offset - 100) < 1e-9)
        #expect(abs(sample.roundTrip - 0.008) < 1e-9)
    }

    @Test func burstKeepsLowestRoundTrip() {
        var burst = ClockSyncBurst()
        for rtt in [0.020, 0.004, 0.011, 0.009, 0.030] {
            burst.add(ClockSample(t0: 0, t1: 50 + rtt / 2, t2: 50 + rtt / 2, t3: rtt))
        }
        #expect(burst.isComplete)
        #expect(abs(burst.best!.roundTrip - 0.004) < 1e-12)
    }

    @Test func clockSampleNeedsCompletePong() {
        #expect(ClockSample(pong: ClockSync(t0: 1), receivedAt: 2) == nil)
        #expect(ClockSample(pong: ClockSync(t0: 1, t1: 5, t2: 6), receivedAt: 2) != nil)
    }
}

/// Real TLS-PSK handshakes over loopback, through the framer and `PeerLink`.
@Suite("Loopback link", .serialized, .timeLimit(.minutes(1)))
struct LoopbackLinkTests {
    private let goodKey = Data(repeating: 0x42, count: 32)
    private let otherKey = Data(repeating: 0x17, count: 32)

    @Test func pairedMacConnectsAndExchangesMessages() async throws {
        let server = try await LoopbackServer(keys: [.paired(macId: macId): goodKey])
        let client = PeerLink(to: server.endpoint, using: LinkParameters.client(key: goodKey, identity: .paired(macId: macId)))
        client.start()

        let hello = Message.hello(Hello(deviceId: macId, deviceName: "Mac", deviceModel: "Mac15,6", appVersion: "0.1.0"))
        let batch = Message.faceBatch(FaceBatch(frames: (0 ..< 6).map { .untracked(at: Double($0) / 60) }))
        var clientEvents = client.events.makeAsyncIterator()
        #expect(await clientEvents.next() == .ready)
        client.send(hello)
        client.send(batch)

        let serverLink = try #require(await server.nextLink())
        var serverEvents = serverLink.events.makeAsyncIterator()
        #expect(await serverEvents.next() == .ready)
        #expect(await serverEvents.next() == .message(hello))
        #expect(await serverEvents.next() == .message(batch))

        serverLink.send(.clockPong(ClockSync(t0: 1, t1: 2, t2: 3)))
        #expect(await clientEvents.nextMessage() == .clockPong(ClockSync(t0: 1, t1: 2, t2: 3)))

        serverLink.cancel()
        #expect(await clientEvents.nextClose() == .peerClosed)
        server.cancel()
    }

    @Test func wrongKeyIsRejected() async throws {
        let server = try await LoopbackServer(keys: [.paired(macId: macId): goodKey])
        let client = PeerLink(to: server.endpoint, using: LinkParameters.client(key: otherKey, identity: .paired(macId: macId)))
        client.start()
        var events = client.events.makeAsyncIterator()
        #expect(await events.nextClose() == .authenticationFailed)
        server.cancel()
    }

    @Test func unknownIdentityIsRejected() async throws {
        let server = try await LoopbackServer(keys: [.paired(macId: macId): goodKey])
        let stranger = UUID()
        let client = PeerLink(to: server.endpoint, using: LinkParameters.client(key: goodKey, identity: .paired(macId: stranger)))
        client.start()
        var events = client.events.makeAsyncIterator()
        #expect(await events.nextClose() == .authenticationFailed)
        server.cancel()
    }

    @Test func unreachablePeerTimesOut() async throws {
        // Nothing listens on the discard port, and TEST-NET-1 never answers.
        let client = PeerLink(to: .hostPort(host: "192.0.2.1", port: 9), using: LinkParameters.client(key: goodKey, identity: .pairing))
        client.start(timeout: .milliseconds(300))
        var events = client.events.makeAsyncIterator()
        let reason = await events.nextClose()
        #expect(reason == .timedOut || reason.map { if case .failed = $0 { true } else { false } } == true)
    }

    @Test func multiKeyListenerAcceptsEachMac() async throws {
        let secondMac = UUID()
        let server = try await LoopbackServer(keys: [.paired(macId: macId): goodKey, .paired(macId: secondMac): otherKey])
        for (id, key) in [(macId, goodKey), (secondMac, otherKey)] {
            let client = PeerLink(to: server.endpoint, using: LinkParameters.client(key: key, identity: .paired(macId: id)))
            client.start()
            var events = client.events.makeAsyncIterator()
            #expect(await events.next() == .ready)
            client.cancel()
        }
        server.cancel()
    }

    @Test func droppedKeyIsRejectedEvenAfterAnEarlierSession() async throws {
        // Session resumption would otherwise let the Mac back in with a cached ticket.
        let first = try await LoopbackServer(keys: [.paired(macId: macId): goodKey])
        let port = first.port
        let client = PeerLink(to: first.endpoint, using: LinkParameters.client(key: goodKey, identity: .paired(macId: macId)))
        client.start()
        var events = client.events.makeAsyncIterator()
        #expect(await events.next() == .ready)
        client.cancel()
        first.cancel()

        let second = try await LoopbackServer.rebinding(keys: [.paired(macId: UUID()): otherKey], port: port)
        let retry = PeerLink(to: second.endpoint, using: LinkParameters.client(key: goodKey, identity: .paired(macId: macId)))
        retry.start()
        var retryEvents = retry.events.makeAsyncIterator()
        #expect(await retryEvents.nextClose() == .authenticationFailed)
        second.cancel()
    }

    @Test func pairingThenLongTermReconnect() async throws {
        let code = Pairing.randomCode()
        let pairingKey = Pairing.pairingKey(code: code, iphoneId: iphoneId).data
        let pairingServer = try await LoopbackServer(keys: [.pairing: pairingKey])

        // A wrong code fails the handshake.
        let wrong = PeerLink(to: pairingServer.endpoint,
                             using: LinkParameters.client(key: Pairing.pairingKey(code: code == "000000" ? "111111" : "000000",
                                                                                  iphoneId: iphoneId).data,
                                                          identity: .pairing))
        wrong.start()
        var wrongEvents = wrong.events.makeAsyncIterator()
        #expect(await wrongEvents.nextClose() == .authenticationFailed)
        _ = await pairingServer.nextLink() // the server side of the failed attempt

        // The right code gets through, and X25519 inside the tunnel yields the same long-term key.
        let macPrivate = Curve25519.KeyAgreement.PrivateKey()
        let client = PeerLink(to: pairingServer.endpoint, using: LinkParameters.client(key: pairingKey, identity: .pairing))
        client.start()
        var clientEvents = client.events.makeAsyncIterator()
        #expect(await clientEvents.next() == .ready)
        client.send(.pairRequest(PairRequest(publicKey: macPrivate.publicKey.rawRepresentation)))

        let serverLink = try #require(await pairingServer.nextLink())
        var serverEvents = serverLink.events.makeAsyncIterator()
        guard case let .pairRequest(request) = await serverEvents.nextMessage() else {
            Issue.record("expected pairRequest")
            return
        }
        let phonePrivate = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = try Pairing.longTermKey(privateKey: phonePrivate, peerPublicKey: request.publicKey,
                                               iphoneId: iphoneId, macId: macId)
        serverLink.send(.pairAccept(PairAccept(publicKey: phonePrivate.publicKey.rawRepresentation)))

        guard case let .pairAccept(accept) = await clientEvents.nextMessage() else {
            Issue.record("expected pairAccept")
            return
        }
        let macKey = try Pairing.longTermKey(privateKey: macPrivate, peerPublicKey: accept.publicKey,
                                             iphoneId: iphoneId, macId: macId)
        #expect(macKey == phoneKey)
        client.cancel()
        pairingServer.cancel()

        let mainServer = try await LoopbackServer(keys: [.paired(macId: macId): phoneKey.data])
        let reconnect = PeerLink(to: mainServer.endpoint,
                                 using: LinkParameters.client(key: macKey.data, identity: .paired(macId: macId)))
        reconnect.start()
        var reconnectEvents = reconnect.events.makeAsyncIterator()
        #expect(await reconnectEvents.next() == .ready)
        reconnect.cancel()
        mainServer.cancel()
    }
}

// MARK: Helpers

private extension AsyncStream<PeerLink.Event>.Iterator {
    mutating func nextMessage() async -> Message? {
        while let event = await next() {
            if case let .message(message) = event { return message }
            if case .closed = event { return nil }
        }
        return nil
    }

    mutating func nextClose() async -> PeerLink.CloseReason? {
        while let event = await next() {
            if case let .closed(reason) = event { return reason }
        }
        return nil
    }
}

/// An `NWListener` on 127.0.0.1 that wraps each incoming connection in a started `PeerLink`.
private final class LoopbackServer: Sendable {
    let listener: NWListener
    let port: NWEndpoint.Port
    private let links: AsyncStream<PeerLink>

    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: port) }

    init(keys: [PSKIdentity: Data], port requested: NWEndpoint.Port = .any) async throws {
        let parameters = LinkParameters.server(keys: keys)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: requested)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)

        let (links, linkContinuation) = AsyncStream<PeerLink>.makeStream()
        self.links = links
        listener.newConnectionHandler = { connection in
            let link = PeerLink(connection: connection)
            link.start()
            linkContinuation.yield(link)
        }

        let listener = listener
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let result: Result<NWEndpoint.Port, any Error>? = switch state {
                case .ready: listener.port.map { .success($0) } ?? .failure(NWError.posix(.EADDRNOTAVAIL))
                case let .failed(error): .failure(error)
                default: nil
                }
                guard let result, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: DispatchQueue(label: "loopback"))
        }
    }

    /// The previous listener on `port` releases it asynchronously, so retry briefly.
    static func rebinding(keys: [PSKIdentity: Data], port: NWEndpoint.Port) async throws -> LoopbackServer {
        for _ in 0 ..< 20 {
            if let server = try? await LoopbackServer(keys: keys, port: port) { return server }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try await LoopbackServer(keys: keys, port: port)
    }

    func nextLink() async -> PeerLink? {
        var iterator = links.makeAsyncIterator()
        return await iterator.next()
    }

    func cancel() {
        listener.cancel()
    }
}
