/// Rolling latency samples with nearest-rank percentiles, for Diagnostics and the M2 checks.
public struct LatencyStats: Sendable, Equatable {
    public let capacity: Int
    public private(set) var samples: [Double] = []

    public init(capacity: Int = 100) {
        self.capacity = capacity
    }

    public mutating func add(_ value: Double) {
        samples.append(value)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public var count: Int { samples.count }
    public var p50: Double? { percentile(50) }
    public var p95: Double? { percentile(95) }

    /// Nearest-rank percentile. `p95` of 20 samples is the 19th smallest.
    public func percentile(_ p: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
