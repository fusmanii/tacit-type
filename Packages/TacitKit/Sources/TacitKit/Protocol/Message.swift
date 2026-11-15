import Foundation

public enum ProtocolDecodeError: Error, Equatable, Sendable {
    case truncated
    case lengthMismatch
    case payloadTooLarge(UInt32)
    case versionMismatch(UInt8)
    case unknownMessageType(UInt8)
    case malformedJSON(String)
}

public enum ProtocolEncodeError: Error, Equatable, Sendable {
    case invalidFaceFrame
    case invalidMouthFrame
    case tooManyFrames
    case payloadTooLarge
}

/// Every message on the Tacit Type wire.
public enum Message: Sendable, Equatable {
    case hello(Hello)
    case start(StartCapture)
    case stop(StopCapture)
    case status(DeviceStatus)
    case clockPing(ClockSync)
    case clockPong(ClockSync)
    case pairRequest(PairRequest)
    case pairAccept(PairAccept)
    case forget(Forget)
    case faceBatch(FaceBatch)
    case audioChunk(AudioChunk)
    case mouthBatch(MouthBatch)
    case error(ProtocolErrorMessage)

    public var type: MessageType {
        switch self {
        case .hello: .hello
        case .start: .start
        case .stop: .stop
        case .status: .status
        case .clockPing: .clockPing
        case .clockPong: .clockPong
        case .pairRequest: .pairRequest
        case .pairAccept: .pairAccept
        case .forget: .forget
        case .faceBatch: .faceBatch
        case .audioChunk: .audioChunk
        case .mouthBatch: .mouthBatch
        case .error: .error
        }
    }

    // MARK: Payload

    public func encodedPayload() throws -> Data {
        switch self {
        case let .hello(payload): try Self.json(payload)
        case let .start(payload): try Self.json(payload)
        case let .stop(payload): try Self.json(payload)
        case let .status(payload): try Self.json(payload)
        case let .clockPing(payload): try Self.json(payload)
        case let .clockPong(payload): try Self.json(payload)
        case let .pairRequest(payload): try Self.json(payload)
        case let .pairAccept(payload): try Self.json(payload)
        case let .forget(payload): try Self.json(payload)
        case let .error(payload): try Self.json(payload)
        case let .faceBatch(batch): try batch.encoded()
        case let .audioChunk(chunk): chunk.encoded()
        case let .mouthBatch(batch): try batch.encoded()
        }
    }

    public init(type: MessageType, payload: Data) throws(ProtocolDecodeError) {
        switch type {
        case .hello: self = .hello(try Self.json(payload))
        case .start: self = .start(try Self.json(payload))
        case .stop: self = .stop(try Self.json(payload))
        case .status: self = .status(try Self.json(payload))
        case .clockPing: self = .clockPing(try Self.json(payload))
        case .clockPong: self = .clockPong(try Self.json(payload))
        case .pairRequest: self = .pairRequest(try Self.json(payload))
        case .pairAccept: self = .pairAccept(try Self.json(payload))
        case .forget: self = .forget(try Self.json(payload))
        case .error: self = .error(try Self.json(payload))
        case .faceBatch: self = .faceBatch(try FaceBatch(decoding: payload))
        case .audioChunk: self = .audioChunk(try AudioChunk(decoding: payload))
        case .mouthBatch: self = .mouthBatch(try MouthBatch(decoding: payload))
        }
    }

    // MARK: Whole frame (header + payload)

    /// Header + payload, for transports that don't use `TacitFramer` (tests, files, debugging).
    public func encodedFrame() throws -> Data {
        let payload = try encodedPayload()
        guard payload.count <= Int(MessageHeader.maxPayloadLength) else { throw ProtocolEncodeError.payloadTooLarge }
        let header = MessageHeader(rawType: type.rawValue, length: UInt32(payload.count))
        return header.encoded() + payload
    }

    public init(frame: Data) throws(ProtocolDecodeError) {
        let header = try MessageHeader(decoding: frame.prefix(MessageHeader.size))
        let payload = frame.dropFirst(MessageHeader.size)
        guard payload.count == Int(header.length) else { throw .lengthMismatch }
        try self.init(header: header, payload: Data(payload))
    }

    /// Validates version and type, then decodes. Used by both `init(frame:)` and the framer path.
    public init(header: MessageHeader, payload: Data) throws(ProtocolDecodeError) {
        guard header.version == Constants.protocolVersion else { throw .versionMismatch(header.version) }
        guard let type = header.type else { throw .unknownMessageType(header.rawType) }
        try self.init(type: type, payload: payload)
    }

    // MARK: JSON

    private static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    private static func json<T: Decodable>(_ data: Data) throws(ProtocolDecodeError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .malformedJSON(String(describing: error))
        }
    }
}
