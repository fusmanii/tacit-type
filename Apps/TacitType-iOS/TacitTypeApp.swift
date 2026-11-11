import ARKit
import TacitKit
import SwiftUI

@main
struct TacitTypeApp: App {
    @State private var model = CamModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// App state from the spec's state table. Capture and networking land in M1 and M2.
@MainActor
@Observable
final class CamModel {
    private(set) var state: DeviceStatus.State

    init() {
        state = ARFaceTrackingConfiguration.isSupported ? .unpaired : .error
    }

    var errorMessage: String {
        "This iPhone has no TrueDepth camera. Tacit Type needs an iPhone with Face ID."
    }
}
