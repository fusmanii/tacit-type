import Darwin
import Foundation

public enum SidecarClientError: Error, Equatable, LocalizedError {
    case pathTooLong
    case connectFailed(Int32)
    case timedOut
    case closed
    case ioFailed(Int32)
    case mismatchedReply(expected: Int, got: Int)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong: "The sidecar socket path is too long"
        case let .connectFailed(code): "Couldn't reach the sidecar (\(String(cString: strerror(code))))"
        case .timedOut: "The sidecar didn't answer in time"
        case .closed: "The sidecar closed the connection"
        case let .ioFailed(code): "Sidecar socket error (\(String(cString: strerror(code))))"
        case let .mismatchedReply(expected, got): "The sidecar answered request \(got), expected \(expected)"
        }
    }
}

/// Sends one request per connection to the sidecar's Unix socket and reads one reply line.
///
/// A connection per request keeps the client stateless, so a restarted sidecar needs no reconnect logic.
/// Connecting to a local socket takes well under a millisecond. The blocking socket calls run off the caller's thread.
public struct SidecarClient: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(_ request: SidecarRequest, timeout: Duration) async throws -> SidecarReply {
        let path = socketPath
        let line = try SidecarProtocol.encode(request)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let data = try await Task.detached { try Self.exchange(line, path: path, timeout: seconds) }.value
        let reply = try SidecarProtocol.decodeReply(data)
        guard reply.id == request.id else { throw SidecarClientError.mismatchedReply(expected: request.id, got: reply.id) }
        return reply
    }

    private static func exchange(_ line: Data, path: String, timeout: Double) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SidecarClientError.ioFailed(errno) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= SidecarProtocol.maxSocketPathBytes else { throw SidecarClientError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw SidecarClientError.connectFailed(errno) }

        try line.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                if n < 0 { throw errno == EAGAIN ? SidecarClientError.timedOut : SidecarClientError.ioFailed(errno) }
                sent += n
            }
        }

        let deadline = Date.now.addingTimeInterval(timeout)
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN ? SidecarClientError.timedOut : SidecarClientError.ioFailed(errno)
            }
            if n == 0 { throw SidecarClientError.closed }
            if let newline = buffer[..<n].firstIndex(of: 0x0A) {
                reply.append(contentsOf: buffer[..<newline])
                return reply
            }
            reply.append(contentsOf: buffer[..<n])
            if Date.now > deadline { throw SidecarClientError.timedOut }
        }
    }
}
