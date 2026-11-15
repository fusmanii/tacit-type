import AppKit
import Observation
import SwiftUI

/// A small panel near the top of the screen that shows what dictation is doing. It never takes focus,
/// so the text still lands in the app the user was typing in.
@MainActor
@Observable
final class HUDController {
    enum Content: Equatable {
        case listening(String)
        case processing(String)
        case progress(String, Double)
        case result(String)
        case message(String)
        case error(String)
    }

    private(set) var content: Content?

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func show(_ content: Content, for seconds: Double? = nil) {
        self.content = content
        hideTask?.cancel()
        present()
        if let seconds {
            hideTask = Task {
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { self.hide() }
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        content = nil
        panel?.orderOut(nil)
    }

    private func present() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 240, height: 44)
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: HUDView(hud: self))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }
}

private struct HUDView: View {
    let hud: HUDController

    var body: some View {
        HStack(spacing: 10) {
            switch hud.content {
            case let .listening(text):
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                    .foregroundStyle(.green)
                Text(text)
            case let .processing(text):
                ProgressView().controlSize(.small)
                Text(text)
            case let .progress(text, fraction):
                ProgressView(value: fraction).frame(width: 80)
                Text("\(text) \(Int(fraction * 100))%").monospacedDigit()
            case let .result(text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(text).lineLimit(2).truncationMode(.tail)
            case let .message(text):
                Image(systemName: "ear").foregroundStyle(.secondary)
                Text(text)
            case let .error(text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(text)
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: Capsule())
        .padding(6)
    }
}
