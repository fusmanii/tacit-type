import Foundation
import TacitKit

/// Settings → Dictation, stored in UserDefaults. The views bind to the same keys with `@AppStorage`.
enum DictationSettings {
    static let wordsKey = "dictationWords"
    static let replacementsKey = "dictationReplacements"
    static let pasteOverridesKey = "dictationPasteOverrides"
    static let polishKey = "dictationPunctuationPolish"

    static let defaultReplacements = """
    new line => \\n
    new paragraph => \\n\\n
    """

    /// Apps where Accessibility insertion is known to misbehave.
    static let defaultPasteOverrides = """
    com.tinyspeck.slackmacgap
    com.microsoft.VSCode
    com.hnc.Discord
    notion.id
    """

    private static var defaults: UserDefaults { .standard }

    static var vocabulary: [String] {
        DictationText.vocabulary(from: defaults.string(forKey: wordsKey) ?? "")
    }

    static var replacements: [DictationText.Replacement] {
        DictationText.replacements(from: defaults.string(forKey: replacementsKey) ?? defaultReplacements)
    }

    static var pasteOverrides: Set<String> {
        Set((defaults.string(forKey: pasteOverridesKey) ?? defaultPasteOverrides)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    static var polishEnabled: Bool { defaults.bool(forKey: polishKey) }
}
