import Foundation
import Network
import os

/// One framed, encrypted connection between the Mac and the iPhone.
///
/// Wraps `NWConnection` with typed `Message` send and receive. Everything that happens on the
/// connection arrives on `events`, in order, and the stream finishes after exactly one `.closed`.
public final class PeerLink: Sendable {
    public enum Event: Sendable, Equatable {
        case ready
        case message(Message)
        /// False while the path is down (Wi-Fi gone, AWDL lost). The link may recover on its own.
        case viabilityChanged(Bool)
        case closed(CloseReason)
    }

    public enum CloseReason: Sendable, Equatable {
        /// `cancel()` was called on this side.
        case cancelled
        /// The peer closed the stream.
        case peerClosed
        /// The TLS-PSK handshake failed. Wrong pairing code, or a key the peer no longer has.
        case authenticationFailed
        /// The peer sent a frame with a different protocol version.
        case versionMismatch(UInt8)
        /// Not ready within the connect timeout. Against a Bonjour endpoint this is also how a wrong
        /// key shows up: when the handshake fails on every path, the connection stays in `preparing`.
        case timedOut
        case failed(String)
    }

    public let events: AsyncStream<Event>
    public let endpoint: NWEndpoint

    private let connection: NWConnection
    private let continuation: AsyncStream<Event>.Continuation
    private let queue = DispatchQueue(label: "com.tacittype.link")
    private let isClosed = OSAllocatedUnfairLock(initialState: false)
    private let isViable = OSAllocatedUnfairLock(initialState: true)
    private let isReady = OSAllocatedUnfairLock(initialState: false)
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "net")

    public init(connection: NWConnection) {
        self.connection = connection
        endpoint = connection.endpoint
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public convenience init(to endpoint: NWEndpoint, using parameters: NWParameters) {
        self.init(connection: NWConnection(to: endpoint, using: parameters))
    }

    /// Starts connecting. Closes with `.timedOut` if the link isn't ready within `timeout`.
    public func start(timeout: Duration = .seconds(5)) {
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        connection.viabilityUpdateHandler = { [weak self] viable in self?.updateViability(viable) }
        connection.start(queue: queue)
        let (seconds, attoseconds) = timeout.components
        queue.asyncAfter(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18) { [weak self] in
            guard let self, !isReady.withLock({ $0 }) else { return }
            close(.timedOut)
        }
    }

    public func send(_ message: Message, completion: (@Sendable () -> Void)? = nil) {
        let payload: Data
        do {
            payload = try message.encodedPayload()
        } catch {
            Self.log.error("Couldn't encode \(String(describing: message.type)): \(error)")
            completion?()
            return
        }
        let framed = NWProtocolFramer.Message(tacitType: message.type)
        let context = NWConnection.ContentContext(identifier: "tacit", metadata: [framed])
        connection.send(content: payload, contentContext: context, isComplete: true,
                        completion: .contentProcessed { error in
                            if let error { Self.log.error("Send failed: \(error)") }
                            completion?()
                        })
    }

    /// Sends one last message, then closes once it has been handed to the network.
    public func send(_ message: Message, thenClose reason: CloseReason) {
        send(message) { [weak self] in self?.close(reason) }
    }

    public func cancel() {
        close(.cancelled)
    }

    // MARK: Private

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady.withLock { $0 = true }
            continuation.yield(.ready)
            receiveNext()
        case let .waiting(error), let .failed(error):
            // A waiting connection would retry forever on its own. The owner decides when to retry.
            close(Self.reason(for: error))
        case .cancelled:
            close(.cancelled)
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self else { return }
            if let error {
                close(Self.reason(for: error))
                return
            }
            guard let framed = context?.protocolMetadata(definition: TacitFramer.definition) as? NWProtocolFramer.Message,
                  let header = framed.tacitHeader
            else {
                if isComplete { close(.peerClosed) } else { receiveNext() }
                return
            }

            do throws(ProtocolDecodeError) {
                continuation.yield(.message(try Message(header: header, payload: content ?? Data())))
            } catch {
                if case let .versionMismatch(version) = error {
                    let reply = ProtocolErrorMessage(code: .versionMismatch,
                                                     message: "Expected protocol \(Constants.protocolVersion), got \(version)")
                    send(.error(reply), thenClose: .versionMismatch(version))
                    return
                }
                Self.log.error("Dropped a bad message: \(String(describing: error))")
                let code: ProtocolErrorMessage.Code = if case .unknownMessageType = error { .unknownMessageType } else { .malformedPayload }
                send(.error(ProtocolErrorMessage(code: code, message: String(describing: error))))
            }
            receiveNext()
        }
    }

    private func updateViability(_ viable: Bool) {
        let changed = isViable.withLock { current in
            defer { current = viable }
            return current != viable
        }
        if changed { continuation.yield(.viabilityChanged(viable)) }
    }

    private func close(_ reason: CloseReason) {
        let first = isClosed.withLock { closed in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        Self.log.info("Link to \(String(describing: self.endpoint), privacy: .public) closed: \(String(describing: reason), privacy: .public)")
        continuation.yield(.closed(reason))
        continuation.finish()
        connection.cancel()
    }

    private static func reason(for error: NWError) -> CloseReason {
        if case .tls = error { return .authenticationFailed }
        if case .posix(.ECONNRESET) = error { return .peerClosed }
        return .failed(error.debugDescription)
    }
}
