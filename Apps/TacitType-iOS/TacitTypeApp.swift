import ARKit
import TacitKit
import SwiftUI

@main
struct TacitTypeApp: App {
    @State private var model = CamModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.link)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // iOS suspends listeners in the background, so bring them back on every return.
            if phase == .active { model.link.start() }
        }
    }
}

/// App state from the spec's state table. Capture lands in M2.
@MainActor
@Observable
final class CamModel {
    let link = LinkServer()
    #if targetEnvironment(simulator)
    // No TrueDepth in the Simulator. Let pairing and the link run there anyway.
    private let hasTrueDepth = true
    #else
    private let hasTrueDepth = ARFaceTrackingConfiguration.isSupported
    #endif

    init() {
        link.currentState = { [weak self] in self?.state ?? .idle }
    }

    var state: DeviceStatus.State {
        if !hasTrueDepth { return .error }
        return link.pairedMacs.isEmpty ? .unpaired : .idle
    }

    var errorMessage: String {
        "This iPhone has no TrueDepth camera. Tacit Type needs an iPhone with Face ID."
    }
}
