import Foundation
import KeyboardShortcuts
import TacitKit

/// The push-to-talk modes a trigger can start.
enum TriggerMode: String, Sendable, CaseIterable {
    case dictate
    case silentDictate

    var sessionMode: SessionMode {
        switch self {
        case .dictate: .dictate
        case .silentDictate: .silent
        }
    }
}

enum TriggerEvent: Sendable, Equatable {
    case began(TriggerMode)
    case ended(TriggerMode)
}

/// Something that turns a user gesture into began / ended events. v1 has `HotkeyTrigger`.
/// An `AirPodsNodTrigger` can be added later without touching the pipelines.
@MainActor
protocol TriggerSource: AnyObject {
    func activate(_ send: @escaping @MainActor (TriggerEvent) -> Void)
}

extension KeyboardShortcuts.Name {
    static let dictate = Self("dictate", default: .init(.space, modifiers: [.control, .option]))
    static let silentDictate = Self("silentDictate", default: .init(.s, modifiers: [.control, .option]))

    static func name(for mode: TriggerMode) -> Self {
        switch mode {
        case .dictate: .dictate
        case .silentDictate: .silentDictate
        }
    }
}

/// Global hotkeys from the KeyboardShortcuts package. Both modes are toggles, so only key-down matters to the pipelines. Users change them in Settings → Hotkeys.
@MainActor
final class HotkeyTrigger: TriggerSource {
    func activate(_ send: @escaping @MainActor (TriggerEvent) -> Void) {
        for mode in TriggerMode.allCases {
            let name = KeyboardShortcuts.Name.name(for: mode)
            KeyboardShortcuts.onKeyDown(for: name) { MainActor.assumeIsolated { send(.began(mode)) } }
            KeyboardShortcuts.onKeyUp(for: name) { MainActor.assumeIsolated { send(.ended(mode)) } }
        }
    }
}

/// Collects every trigger source and hands one ordered stream of events to its handler.
/// A key-down while that mode is already held (key repeat) is dropped, and so is a key-up with no key-down.
@MainActor
final class TriggerCenter {
    private var sources: [TriggerSource] = []
    private var held: Set<TriggerMode> = []
    var handler: (@MainActor (TriggerEvent) -> Void)?

    func add(_ source: TriggerSource) {
        sources.append(source)
        source.activate { [weak self] event in self?.route(event) }
    }

    private func route(_ event: TriggerEvent) {
        switch event {
        case let .began(mode):
            guard held.insert(mode).inserted else { return }
        case let .ended(mode):
            guard held.remove(mode) != nil else { return }
        }
        handler?(event)
    }

    /// For the menu: "⌃⌥Space", or "Not set".
    static func shortcutText(for mode: TriggerMode) -> String {
        KeyboardShortcuts.getShortcut(for: .name(for: mode))?.description ?? "Not set"
    }
}
