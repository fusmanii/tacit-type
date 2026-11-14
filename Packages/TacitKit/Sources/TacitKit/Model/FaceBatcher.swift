/// Groups face frames into `faceBatch` messages on the iPhone.
///
/// Each batch covers `[first.timestamp, first.timestamp + interval)` of frame time, so the cadence
/// follows ARKit's clock rather than a timer. At 60 fps that is 6 frames per batch.
/// `flush()` empties it early, for `stop`.
public struct FaceBatcher: Sendable {
    public let interval: Double
    private var frames: [FaceFrame] = []

    public init(interval: Double = Constants.faceBatchInterval) {
        self.interval = interval
    }

    public var isEmpty: Bool { frames.isEmpty }

    /// Adds a frame. Returns the previous batch when this frame falls outside its window.
    public mutating func append(_ frame: FaceFrame) -> FaceBatch? {
        var due: FaceBatch?
        if let first = frames.first, frame.timestamp - first.timestamp >= interval - 1e-6 {
            due = flush()
        }
        frames.append(frame)
        return due
    }

    /// Returns whatever is pending, or nil if nothing is.
    public mutating func flush() -> FaceBatch? {
        guard !frames.isEmpty else { return nil }
        defer { frames.removeAll(keepingCapacity: true) }
        return FaceBatch(frames: frames)
    }
}
