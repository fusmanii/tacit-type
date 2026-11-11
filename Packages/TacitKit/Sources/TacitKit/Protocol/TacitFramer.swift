import Foundation
import Network

/// `NWProtocolFramer` that adds the 8-byte Tacit Type header to each message.
///
/// Sending: attach `NWProtocolFramer.Message(tacitType:)` as the content context's metadata.
/// Receiving: read `message.tacitHeader` from the received context's metadata, then
/// `Message(header:payload:)` to decode.
public final class TacitFramer: NWProtocolFramerImplementation {
    public static let definition = NWProtocolFramer.Definition(implementation: TacitFramer.self)
    public static var label: String { "Tacit Type" }

    public required init(framer: NWProtocolFramer.Instance) {}

    public func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    public func wakeup(framer: NWProtocolFramer.Instance) {}
    public func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    public func cleanup(framer: NWProtocolFramer.Instance) {}

    public func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                             messageLength: Int, isComplete: Bool) {
        guard let type = message.tacitType,
              messageLength <= Int(MessageHeader.maxPayloadLength)
        else {
            framer.markFailed(error: .posix(.EBADMSG))
            return
        }
        let header = MessageHeader(rawType: type.rawValue, length: UInt32(messageLength))
        framer.writeOutput(data: header.encoded())
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: .posix(.EIO))
        }
    }

    public func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var parsed: Result<MessageHeader, ProtocolDecodeError>?
            let complete = framer.parseInput(minimumIncompleteLength: MessageHeader.size,
                                             maximumLength: MessageHeader.size) { buffer, _ in
                guard let buffer, buffer.count >= MessageHeader.size else { return 0 }
                parsed = Result { () throws(ProtocolDecodeError) in try MessageHeader(decoding: Data(buffer)) }
                return MessageHeader.size
            }
            guard complete, let parsed else { return MessageHeader.size }

            switch parsed {
            case let .success(header):
                let message = NWProtocolFramer.Message(definition: Self.definition)
                message.tacitHeader = header
                guard framer.deliverInputNoCopy(length: Int(header.length), message: message, isComplete: true) else {
                    return 0
                }
            case .failure:
                framer.markFailed(error: .posix(.EBADMSG))
                return 0
            }
        }
    }
}

extension NWProtocolFramer.Message {
    private static let headerKey = "tacit.header"
    private static let typeKey = "tacit.type"

    public convenience init(tacitType: MessageType) {
        self.init(definition: TacitFramer.definition)
        self[Self.typeKey] = tacitType
    }

    public var tacitType: MessageType? {
        self[Self.typeKey] as? MessageType
    }

    public internal(set) var tacitHeader: MessageHeader? {
        get { self[Self.headerKey] as? MessageHeader }
        set { self[Self.headerKey] = newValue }
    }
}
