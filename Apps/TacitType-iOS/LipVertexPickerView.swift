import ARKit
import SceneKit
import SwiftUI
import TacitKit
import os

/// One-off developer screen that chooses `Constants.lipVertexIndices` and `Constants.cropLandmarkIndices`.
///
/// The 12 crop landmarks (blue) come from `CropLandmarkSelector` on the same neutral capture. With
/// no capture yet they show what the iPhone uses now, hardcoded or picked from ARKit's neutral face.
///
/// Hold a neutral face and tap Capture. `LipVertexSelector` finds the inner lip contour, keeps the
/// vertices near it and farthest-point samples 64. They're drawn on the live face mesh for review.
/// Copy puts a Swift literal on the pasteboard (and in the log) to paste into Constants.swift.
/// With no capture yet, the screen shows the indices already in Constants, so they can be re-reviewed.
struct LipVertexPickerView: View {
    @Environment(CamModel.self) private var model
    @State private var scene = PickerScene()
    @State private var radiusMM: Float = 9
    @State private var neutral: (vertices: [SIMD3<Float>], triangles: [Int])?
    @State private var selection: LipVertexSelector.Selection?
    @State private var message: String?
    @State private var hasCamera = false
    @State private var copied = false
    @State private var cropLandmarks: [Int]?
    @State private var copiedCrop = false
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "session")

    var body: some View {
        ZStack(alignment: .bottom) {
            if hasCamera {
                PickerSceneView(scene: scene).ignoresSafeArea()
            } else {
                ContentUnavailableView("Camera in use", systemImage: "camera",
                                       description: Text("A Mac is capturing. Try again when it stops."))
            }
            controls
        }
        .navigationTitle("Lip Vertices")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hasCamera = model.claimCameraForPicker()
            if hasCamera {
                scene.start()
                showHardcoded()
            }
        }
        .onDisappear {
            scene.stop()
            if hasCamera { model.releaseCameraFromPicker() }
        }
        .onChange(of: radiusMM) { _, _ in runSelection() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            if let message {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
            HStack {
                Text("Radius \(radiusMM, format: .number.precision(.fractionLength(1))) mm")
                    .font(.footnote.monospacedDigit())
                Slider(value: $radiusMM, in: 3 ... 12, step: 0.5)
            }
            .disabled(neutral == nil)
            HStack {
                Button("Capture Neutral Face", systemImage: "face.smiling", action: captureNeutral)
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button(copied ? "Copied" : "Copy Swift", systemImage: "doc.on.doc", action: copy)
                    .disabled(selection == nil)
            }
            HStack {
                Text(cropSummary).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button(copiedCrop ? "Copied" : "Copy Crop Landmarks", systemImage: "doc.on.doc", action: copyCrop)
                    .disabled(cropLandmarks == nil)
            }
            Text("Green: chosen. Yellow: mouth corners (slots 0 and 1). Red: inner lip contour. Grey: candidates. Blue: crop landmarks.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .padding()
        .disabled(!hasCamera)
    }

    private var summary: String {
        if let selection {
            return "\(selection.indices.count) chosen of \(selection.candidates.count) candidates · contour \(selection.contour.count) · corners \(selection.indices[0]), \(selection.indices[1])"
        }
        if !Constants.lipVertexIndices.isEmpty {
            return "Showing the \(Constants.lipVertexIndices.count) hardcoded indices. Capture to pick new ones."
        }
        return "No indices hardcoded yet. Keep a relaxed, closed mouth and capture."
    }

    private var cropSummary: String {
        if let cropLandmarks { return "Crop landmarks: \(cropLandmarks.map(String.init).joined(separator: ", "))" }
        return Constants.cropLandmarkIndices.isEmpty ? "Crop landmarks: picked from ARKit's neutral face" : "Crop landmarks: hardcoded"
    }

    private func showHardcoded() {
        let indices = Constants.lipVertexIndices
        var markers = indices.enumerated().map { slot, index in
            PickerScene.Marker(index: index, kind: slot < 2 ? .corner : .chosen)
        }
        markers += CaptureController.cropLandmarkIndices.map { PickerScene.Marker(index: $0, kind: .crop) }
        scene.setMarkers(markers)
    }

    private func captureNeutral() {
        guard let geometry = scene.currentGeometry() else {
            message = "No face in view. Look at the phone and try again."
            return
        }
        guard geometry.vertices.count == Constants.faceMeshVertexCount else {
            message = "The mesh has \(geometry.vertices.count) vertices, expected \(Constants.faceMeshVertexCount)."
            return
        }
        neutral = geometry
        runSelection()
    }

    private func selectCropLandmarks() -> [Int]? {
        guard let neutral else { return nil }
        let corners = selection.map { (low: $0.indices[0], high: $0.indices[1]) } ?? CropLandmarkSelector.lipCorners
        do {
            return try CropLandmarkSelector.select(vertices: neutral.vertices, triangleIndices: neutral.triangles, mouthCorners: corners)
        } catch {
            message = "Couldn't pick crop landmarks: \(error)"
            return nil
        }
    }

    private func runSelection() {
        guard let neutral else { return }
        copied = false
        do {
            let options = LipVertexSelector.Options(radius: radiusMM / 1000)
            let result = try LipVertexSelector.select(vertices: neutral.vertices, triangleIndices: neutral.triangles,
                                                      options: options)
            selection = result
            message = nil
            let chosen = Set(result.indices)
            var markers = result.candidates.filter { !chosen.contains($0) }.map { PickerScene.Marker(index: $0, kind: .candidate) }
            markers += result.contour.filter { !chosen.contains($0) }.map { PickerScene.Marker(index: $0, kind: .contour) }
            markers += result.indices.enumerated().map { slot, index in
                PickerScene.Marker(index: index, kind: slot < 2 ? .corner : .chosen)
            }
            cropLandmarks = selectCropLandmarks()
            copiedCrop = false
            markers += (cropLandmarks ?? []).map { PickerScene.Marker(index: $0, kind: .crop) }
            scene.setMarkers(markers)
        } catch {
            selection = nil
            message = switch error {
            case .noMouthOpening: "Couldn't find the mouth opening in the mesh."
            case let .notEnoughCandidates(found, needed): "Only \(found) vertices within the radius, need \(needed). Widen it."
            }
        }
    }

    private func copy() {
        guard let selection else { return }
        let rows = stride(from: 0, to: selection.indices.count, by: 16).map { start in
            selection.indices[start ..< min(start + 16, selection.indices.count)].map(String.init).joined(separator: ", ")
        }
        let literal = "public static let lipVertexIndices: [Int] = [\n" + rows.map { "    \($0)," }.joined(separator: "\n") + "\n]"
        UIPasteboard.general.string = literal
        Self.log.notice("Lip vertex indices (radius \(radiusMM) mm):\n\(literal, privacy: .public)")
        copied = true
    }

    private func copyCrop() {
        guard let cropLandmarks else { return }
        let names = CropLandmark.allCases.map { "\($0)" }.joined(separator: ", ")
        let literal = "/// Slots: \(names)\npublic static let cropLandmarkIndices: [Int] = [\n    "
            + cropLandmarks.map(String.init).joined(separator: ", ") + ",\n]"
        UIPasteboard.general.string = literal
        Self.log.notice("Crop landmark indices:\n\(literal, privacy: .public)")
        copiedCrop = true
    }
}

/// Owns the ARSCNView and draws the face mesh plus marker dots that follow the live mesh.
@MainActor
final class PickerScene: NSObject, ARSCNViewDelegate {
    struct Marker: Sendable {
        enum Kind: Sendable { case candidate, contour, chosen, corner, crop }
        var index: Int
        var kind: Kind
    }

    let view = ARSCNView()
    /// Read on SceneKit's render thread, written on main.
    private let markers = OSAllocatedUnfairLock<(version: Int, list: [Marker])>(initialState: (0, []))
    nonisolated(unsafe) private var drawnVersion = -1
    nonisolated(unsafe) private var dotNodes: [SCNNode] = []

    override init() {
        super.init()
        view.delegate = self
        view.automaticallyUpdatesLighting = true
        view.backgroundColor = .black
    }

    func start() {
        guard ARFaceTrackingConfiguration.isSupported else { return }
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        view.session.pause()
    }

    func currentGeometry() -> (vertices: [SIMD3<Float>], triangles: [Int])? {
        guard let anchor = view.session.currentFrame?.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first,
              anchor.isTracked
        else { return nil }
        return (anchor.geometry.vertices, anchor.geometry.triangleIndices.map(Int.init))
    }

    func setMarkers(_ list: [Marker]) {
        markers.withLock { $0 = ($0.version + 1, list) }
    }

    nonisolated func renderer(_ renderer: any SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard anchor is ARFaceAnchor, let device = renderer.device, let mesh = ARSCNFaceGeometry(device: device) else { return nil }
        mesh.firstMaterial?.fillMode = .lines
        mesh.firstMaterial?.diffuse.contents = UIColor.white.withAlphaComponent(0.25)
        mesh.firstMaterial?.lightingModel = .constant
        return SCNNode(geometry: mesh)
    }

    nonisolated func renderer(_ renderer: any SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let anchor = anchor as? ARFaceAnchor, let mesh = node.geometry as? ARSCNFaceGeometry else { return }
        mesh.update(from: anchor.geometry)

        let (version, list) = markers.withLock { $0 }
        if version != drawnVersion {
            drawnVersion = version
            dotNodes.forEach { $0.removeFromParentNode() }
            dotNodes = list.map { marker in
                let dot = SCNNode(geometry: Self.dotGeometry[marker.kind])
                node.addChildNode(dot)
                return dot
            }
        }
        let vertices = anchor.geometry.vertices
        for (dot, marker) in zip(dotNodes, list) where marker.index < vertices.count {
            dot.simdPosition = vertices[marker.index]
        }
    }

    /// Only used on the render thread.
    nonisolated(unsafe) private static let dotGeometry: [Marker.Kind: SCNGeometry] = {
        func sphere(_ radius: CGFloat, _ color: UIColor) -> SCNGeometry {
            let sphere = SCNSphere(radius: radius)
            sphere.segmentCount = 8
            sphere.firstMaterial?.diffuse.contents = color
            sphere.firstMaterial?.lightingModel = .constant
            return sphere
        }
        return [
            .candidate: sphere(0.0004, .lightGray),
            .contour: sphere(0.0006, .systemRed),
            .chosen: sphere(0.0008, .systemGreen),
            .corner: sphere(0.0011, .systemYellow),
            .crop: sphere(0.0014, .systemBlue),
        ]
    }()
}

private struct PickerSceneView: UIViewRepresentable {
    let scene: PickerScene

    func makeUIView(context: Context) -> ARSCNView { scene.view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
