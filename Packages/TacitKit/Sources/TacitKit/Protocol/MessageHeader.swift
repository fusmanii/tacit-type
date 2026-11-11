import Foundation

public enum MessageType: UInt8, Sendable, CaseIterable {
    case hello = 0x01
    case start = 0x02
    case stop = 0x03
    case status = 0x04
    case clockPing = 0x05
    case clockPong = 0x06
    case faceBatch = 0x10
    case audioChunk = 0x11
    case error = 0x7F
}

/// 8-byte frame header: type, version, 2 reserved bytes, UInt32 little-endian payload length.
public struct MessageHeader: Sendable, Equatable {
    public static let size = 8
    /// Upper bound on a single payload. Anything larger is treated as a corrupt stream.
    public static let maxPayloadLength: UInt32 = 4 * 1024 * 1024

    public var rawType: UInt8
    public var version: UInt8
    public var length: UInt32

    public init(rawType: UInt8, version: UInt8 = Constants.protocolVersion, length: UInt32) {
        self.rawType = rawType
        self.version = version
        self.length = length
    }

    public var type: MessageType? { MessageType(rawValue: rawType) }

    public func encoded() -> Data {
        var writer = ByteWriter(capacity: Self.size)
        writer.write(rawType)
        writer.write(version)
        writer.write(UInt16(0))
        writer.write(length)
        return writer.data
    }

    public init(decoding data: Data) throws(ProtocolDecodeError) {
        var reader = ByteReader(data)
        rawType = try reader.read()
        version = try reader.read()
        _ = try reader.read(UInt16.self)
        length = try reader.read()
        guard length <= Self.maxPayloadLength else { throw .payloadTooLarge(length) }
    }
}
