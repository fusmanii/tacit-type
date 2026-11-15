import Foundation
import TacitKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional LLM polish for dictation: Apple's on-device model fixes punctuation only, within 400 ms.
/// On timeout, on failure, or before macOS 26 the raw text is used.
///
/// Built only with the macOS 26 SDK (Xcode 26). With older SDKs `isAvailable` is always false.
/// Not yet run on a Mac with macOS 26.
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

    static func polish(_ text: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), SystemLanguageModel.default.isAvailable {
            let polished = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    let session = LanguageModelSession(instructions: """
                    You fix punctuation and capitalisation in dictated text. Never add, remove, reorder or change words. \
                    Reply with the corrected text only.
                    """)
                    return try? await session.respond(to: text).content
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
