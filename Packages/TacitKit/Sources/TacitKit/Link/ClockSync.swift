import Foundation

/// The host clock that `ARFrame.timestamp` and audio PTS use (`mach_absolute_time`, as `CACurrentMediaTime`).
public enum HostClock {
    public static func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }
}

/// One `clockPing` / `clockPong` round, all in seconds.
///
/// `t0` pinger sends, `t1` ponger receives, `t2` ponger replies, `t3` pinger receives the reply.
/// `t0` and `t3` are on the pinger's clock, `t1` and `t2` on the ponger's.
public struct ClockSample: Sendable, Equatable {
    public var t0, t1, t2, t3: Double

    public init(t0: Double, t1: Double, t2: Double, t3: Double) {
        (self.t0, self.t1, self.t2, self.t3) = (t0, t1, t2, t3)
    }

    /// `ClockSync` pong plus the local receive time. Nil if the pong is missing a field.
    public init?(pong: ClockSync, receivedAt t3: Double) {
        guard let t1 = pong.t1, let t2 = pong.t2 else { return nil }
        self.init(t0: pong.t0, t1: t1, t2: t2, t3: t3)
    }

    /// Round trip on the wire, excluding the ponger's turnaround.
    public var roundTrip: Double { (t3 - t0) - (t2 - t1) }

    /// Ponger clock minus pinger clock. Standard NTP estimate, exact when the two legs are symmetric.
    public var offset: Double { ((t1 - t0) + (t2 - t3)) / 2 }
}

/// Collects one burst of rounds and keeps the one with the lowest round trip.
public struct ClockSyncBurst: Sendable {
    public static let rounds = 5
    /// The spec runs a burst on connect and every 10 s.
    public static let interval: Duration = .seconds(10)

    public private(set) var samples: [ClockSample] = []

    public init() {}

    public var isComplete: Bool { samples.count >= Self.rounds }

    public mutating func add(_ sample: ClockSample) {
        samples.append(sample)
    }

    public var best: ClockSample? { samples.min { $0.roundTrip < $1.roundTrip } }
}
