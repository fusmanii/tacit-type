import Foundation
import TacitKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Phase C: Apple's on-device model picks the sentence the user most likely mouthed from the lip
/// reader's n-best list, within 800 ms. On timeout, on a rejected reply, or without the model, the
/// top hypothesis is used.
///
/// The model's first call is slow (about 1.5 s against 0.26 s after, checked in M5a), so a prewarmed
/// session always waits for the next dictation. Each dictation uses a fresh session, so earlier
/// guesses never leak into the next one.
@MainActor
enum SilentCleanup {
    static let timeout: Duration = .milliseconds(800)

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    #if canImport(FoundationModels)
    private static var next: (any Sendable)?
    #endif

    /// Loads the model and readies a session for the next dictation. Cheap to call again.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable, next == nil {
            let session = LanguageModelSession(instructions: SilentDictation.cleanupInstructions)
            session.prewarm()
            next = SessionBox(session: session)
        }
        #endif
    }

    /// The LLM's sentence, or nil when it timed out, failed or gave an unusable reply.
    static func pick(from hypotheses: [String], appName: String?) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable, !hypotheses.isEmpty {
            prewarm()
            guard let session = (next as? SessionBox)?.session else { return nil }
            next = nil
            defer { prewarm() }
            let prompt = SilentDictation.cleanupPrompt(hypotheses: hypotheses, appName: appName)
            let longest = hypotheses.map { $0.split(separator: " ").count }.max() ?? 0
            // The macOS 27 SDK (Swift 6.4) renamed `sampling:` to `samplingMode:`. CI still builds with Xcode 26.
            #if compiler(>=6.4)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 4 * longest + 16)
            #else
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 4 * longest + 16)
            #endif
            let box = SessionBox(session: session)
            let output = await withTaskGroup(of: String?.self) { group in
                group.addTask { try? await box.session.respond(to: prompt, options: options).content }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            return SilentDictation.acceptCleanup(output, hypotheses: hypotheses)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
/// Carries a session into a task. The macOS 27 SDK marks `LanguageModelSession` Sendable, and older
/// SDKs may not. Each session is used by one dictation at a time, so sharing it is safe.
@available(macOS 26, *)
struct SessionBox: @unchecked Sendable {
    let session: LanguageModelSession
}
#endif
