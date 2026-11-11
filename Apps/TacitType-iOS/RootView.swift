import SwiftUI

struct RootView: View {
    @Environment(CamModel.self) private var model

    var body: some View {
        switch model.state {
        case .unpaired:
            ContentUnavailableView("Pair with your Mac", systemImage: "macbook.and.iphone",
                                   description: Text("Open Tacit Type on your Mac and choose Pair new iPhone…"))
        case .idle, .capturing:
            DockView(isCapturing: model.state == .capturing)
        case .error:
            ContentUnavailableView("Tacit Type can't run", systemImage: "exclamationmark.triangle",
                                   description: Text(model.errorMessage))
        }
    }
}

/// Black dock screen with a small status dot. Green while capturing.
struct DockView: View {
    let isCapturing: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            Circle()
                .fill(isCapturing ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 12)
        }
    }
}

#Preview("Dock") { DockView(isCapturing: true) }
