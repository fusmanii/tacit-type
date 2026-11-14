import Foundation

/// Appends little-endian scalars to a `Data` buffer.
struct ByteWriter {
    private(set) var data: Data

    init(capacity: Int = 0) {
        data = Data(capacity: capacity)
    }

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(bytes: some Sequence<UInt8>) { data.append(contentsOf: bytes) }

    mutating func write(_ value: Float) { write(value.bitPattern) }
    mutating func write(_ value: Double) { write(value.bitPattern) }
}

/// Reads little-endian scalars from a `Data` buffer with bounds checks.
struct ByteReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func read<T: FixedWidthInteger>(_: T.Type = T.self) throws(ProtocolDecodeError) -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw .truncated }
        var value = T.zero
        _ = withUnsafeMutableBytes(of: &value) { dst in
            data.copyBytes(to: dst, from: offset ..< offset + size)
        }
        offset += size
        return T(littleEndian: value)
    }

    mutating func readBytes(_ count: Int) throws(ProtocolDecodeError) -> Data {
        guard count >= 0, remaining >= count else { throw .truncated }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }

    mutating func read(_: Float.Type = Float.self) throws(ProtocolDecodeError) -> Float {
        Float(bitPattern: try read(UInt32.self))
    }

    mutating func read(_: Double.Type = Double.self) throws(ProtocolDecodeError) -> Double {
        Double(bitPattern: try read(UInt64.self))
    }
}
