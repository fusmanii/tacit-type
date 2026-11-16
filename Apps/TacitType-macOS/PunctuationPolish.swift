import Foundation
import TacitKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional LLM polish for dictation: Apple's on-device model fixes punctuation only, within 400 ms.
/// On timeout, on failure, or before macOS 26 the raw text is used.
///
/// Built only with the macOS 26 SDK (Xcode 26). With older SDKs `isAvailable` is always false.
@MainActor
enum PunctuationPolish {
    static let timeout: Duration = .milliseconds(400)

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    static let instructions = """
    You fix punctuation and capitalisation in dictated text. Never add, remove, reorder or change words. \
    Reply with the corrected text only.
    """

    #if canImport(FoundationModels)
    /// A prewarmed session for the next dictation, since the model's first call is slow.
    private static var next: (any Sendable)?
    #endif

    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable, DictationSettings.polishEnabled, next == nil {
            let session = LanguageModelSession(instructions: instructions)
            session.prewarm()
            next = session
        }
        #endif
    }

    static func polish(_ text: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), SystemLanguageModel.default.isAvailable {
            let session = next as? LanguageModelSession ?? LanguageModelSession(instructions: instructions)
            next = nil
            defer { prewarm() }
            let polished = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    try? await session.respond(to: text).content
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let polished, WordErrorRate.normalise(polished) == WordErrorRate.normalise(text) {
                return polished.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        #endif
        return text
    }
}
