import Foundation

/// Retry delays after a dropped connection: 0.5 s, 1 s, 2 s, then 5 s for every later attempt.
public struct ReconnectBackoff: Sendable {
    public static let delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5)]

    private var attempt = 0

    public init() {}

    public mutating func next() -> Duration {
        defer { attempt += 1 }
        return Self.delays[min(attempt, Self.delays.count - 1)]
    }

    public mutating func reset() {
        attempt = 0
    }
}
