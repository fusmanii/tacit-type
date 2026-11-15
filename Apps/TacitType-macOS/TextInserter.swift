import AppKit
import ApplicationServices
import os
import TacitKit

/// Puts text into the focused app.
///
/// First it sets the focused element's selected text through Accessibility, which replaces the selection
/// or inserts at the caret. When that fails, or the app takes the call but changes nothing (many Electron
/// apps), it pastes: snapshot the pasteboard, write the text, post ⌘V, wait 150 ms, restore the pasteboard.
@MainActor
enum TextInserter {
    enum Method: String, Sendable {
        case accessibility, paste
    }

    static let pasteSettle: Duration = .milliseconds(150)
    private static let log = Logger(subsystem: Constants.logSubsystem, category: "dictation")

    /// Bundle ids of the app that will receive the text.
    static var frontmostBundleId: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    static func insert(_ text: String, forcePasteFor bundleIds: Set<String>) async -> Method {
        if let app = frontmostBundleId, bundleIds.contains(app) {
            await paste(text)
            return .paste
        }
        if insertWithAccessibility(text) { return .accessibility }
        await paste(text)
        return .paste
    }

    // MARK: Accessibility

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private static func insertWithAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        let element = focused as! AXUIElement

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue
        else { return false }

        let before = value(of: element)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }
        // An app that ignores the call still reports success. If its value is readable and didn't change, paste.
        if let before, let after = value(of: element), before == after {
            log.info("AX insert into \(frontmostBundleId ?? "?", privacy: .public) changed nothing, pasting")
            return false
        }
        return true
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: Paste

    /// Every item on the pasteboard, with every type it carries.
    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static func snapshot(_ board: NSPasteboard) -> Snapshot {
        (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ snapshot: Snapshot, to board: NSPasteboard) {
        board.clearContents()
        let items = snapshot.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }

    static func paste(_ text: String) async {
        let board = NSPasteboard.general
        let saved = snapshot(board)
        board.clearContents()
        board.setString(text, forType: .string)
        // Tells clipboard managers not to keep the dictated text (nspasteboard.org).
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ours = board.changeCount

        postCommandV()
        try? await Task.sleep(for: pasteSettle)

        // If something else wrote to the pasteboard meanwhile, leave it alone.
        guard board.changeCount == ours else {
            log.notice("Pasteboard changed during paste, not restoring")
            return
        }
        restore(saved, to: board)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            // Set explicitly, so the ⌃⌥ the user may still be holding from the hotkey doesn't turn ⌘V into ⌃⌥⌘V.
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
