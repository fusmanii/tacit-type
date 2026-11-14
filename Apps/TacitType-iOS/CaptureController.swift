import ARKit
import TacitKit
import os

/// Runs ARKit face tracking for one session at a time and streams it to the Mac.
///
/// Delegate callbacks, batching and sends all happen on `queue`, never on main. `start` and `stop`
/// are called from the main actor. Leaving a session always pauses the `ARSession`, so the camera
/// indicator is never on outside one.
final class CaptureController: NSObject, ARSessionDelegate, @unchecked Sendable {
    struct Tracking: Equatable, Sendable {
        var state: DeviceStatus.TrackingState = .notAvailable
        var faceDetected = false
    }

    enum StartError: Error, CustomStringConvertible {
        case unsupported

        var description: String { "Face tracking isn't supported on this iPhone." }
    }

    /// Called on the main actor when the face appears or disappears, or tracking quality changes.
    @MainActor var onTrackingChange: ((Tracking) -> Void)?
    /// Called on the main actor when capture can't continue. The owner must call `stop()`.
    @MainActor var onFailure: ((String) -> Void)?

    private let session = ARSession()
    private let queue = DispatchQueue(label: "com.tacittype.capture", qos: .userInteractive)
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "session")
    private static let locations = Constants.blendShapeOrder.map(ARFaceAnchor.BlendShapeLocation.init(rawValue:))

    // Everything below is only touched on `queue`.
    private struct Active {
        var sessionId: UUID
        var link: PeerLink
        var startedAt: Double
        var firstFrameLogged = false
        var frameCount = 0
    }

    private var active: Active?
    private var batcher = FaceBatcher()
    private var resampler = AudioResampler()
    private var tracking = Tracking()
    private var meshChecked = false

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }


    @MainActor
    func start(sessionId: UUID, streams: [StreamKind], link: PeerLink) throws {
        guard Self.isSupported else { throw StartError.unsupported }
        let startedAt = HostClock.now()
        queue.sync {
            active = Active(sessionId: sessionId, link: link, startedAt: startedAt)
            batcher = FaceBatcher()
            resampler.reset()
            tracking = Tracking()
            meshChecked = false
        }

        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.isLightEstimationEnabled = false
        configuration.providesAudioData = streams.contains(.audio)
        if let fastest = ARFaceTrackingConfiguration.supportedVideoFormats.max(by: { $0.framesPerSecond < $1.framesPerSecond }) {
            configuration.videoFormat = fastest
        }
        // Camera power-on takes about 420 ms whatever the options or format (measured in M2).
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        Self.log.info("Capture \(sessionId, privacy: .public) started at \(configuration.videoFormat.framesPerSecond) fps, audio \(configuration.providesAudioData)")
    }

    /// Pauses ARKit, then sends what's left of the batch. Returns once every send for the session is queued.
    @MainActor
    func stop() async {
        session.pause()
        await withCheckedContinuation { continuation in
            queue.async {
                self.finish()
                continuation.resume()
            }
        }
    }

    // MARK: Queue

    private func finish() {
        guard let active else { return }
        if let batch = batcher.flush() { active.link.send(.faceBatch(batch)) }
        let elapsed = HostClock.now() - active.startedAt
        Self.log.info("Capture \(active.sessionId, privacy: .public) stopped after \(elapsed, format: .fixed(precision: 2)) s, \(active.frameCount) frames")
        self.active = nil
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard var active else { return }
        let anchor = frame.anchors.lazy.compactMap { $0 as? ARFaceAnchor }.first

        if let anchor, !meshChecked {
            meshChecked = true
            let count = anchor.geometry.vertices.count
            guard count == Constants.faceMeshVertexCount else {
                Self.log.fault("Face mesh has \(count) vertices, expected \(Constants.faceMeshVertexCount). Lip indices would be wrong.")
                self.active = nil
                fail("This iOS version changed the face mesh, so Tacit Type can't capture. Update Tacit Type.")
                return
            }
        }

        let faceFrame = Self.makeFrame(frame, anchor: anchor)
        if !active.firstFrameLogged {
            active.firstFrameLogged = true
            let latency = (frame.timestamp - active.startedAt) * 1000
            Self.log.info("First face frame \(latency, format: .fixed(precision: 0)) ms after start")
        }
        active.frameCount += 1
        self.active = active
        if let batch = batcher.append(faceFrame) { active.link.send(.faceBatch(batch)) }

        let now = Tracking(state: Self.trackingState(frame.camera.trackingState),
                           faceDetected: faceFrame.trackingFlags.contains(.isTracked))
        if now != tracking {
            tracking = now
            Task { @MainActor in self.onTrackingChange?(now) }
        }
    }

    func session(_ session: ARSession, didOutputAudioSampleBuffer audioSampleBuffer: CMSampleBuffer) {
        guard let active, let chunk = resampler.convert(audioSampleBuffer) else { return }
        active.link.send(.audioChunk(chunk))
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        Self.log.error("ARSession failed: \(error)")
        fail("Face tracking stopped: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        Self.log.notice("ARSession interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        Self.log.notice("ARSession interruption ended")
    }

    private func fail(_ message: String) {
        Task { @MainActor in self.onFailure?(message) }
    }

    // MARK: Packing

    private static func makeFrame(_ frame: ARFrame, anchor: ARFaceAnchor?) -> FaceFrame {
        guard let anchor, anchor.isTracked else { return .untracked(at: frame.timestamp) }

        var flags: TrackingFlags = .isTracked
        if case .normal = frame.camera.trackingState { flags.insert(.trackingNormal) }

        let shapes = anchor.blendShapes
        let blendShapes = locations.map { shapes[$0]?.floatValue ?? 0 }
        let m = anchor.transform
        let headTransform = [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }

        let vertices = anchor.geometry.vertices
        let lipVertices = Constants.lipVertexIndices.map { vertices[$0] }

        return FaceFrame(timestamp: frame.timestamp, trackingFlags: flags, blendShapes: blendShapes,
                         headTransform: headTransform, lipVertices: lipVertices)
    }

    private static func trackingState(_ state: ARCamera.TrackingState) -> DeviceStatus.TrackingState {
        switch state {
        case .normal: .normal
        case .limited: .limited
        case .notAvailable: .notAvailable
        }
    }
}
