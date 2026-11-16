import Foundation

/// The pure parts of silent dictation (Step 3). The Mac app's `SilentDictationPipeline` wires them
/// around the lip-reading sidecar and the on-device LLM.
public enum SilentDictation {
    /// Over this share of voiced audio inside the open regions, the user spoke aloud.
    public static let aloudVoicedRatio = 0.5
    /// Both lip-reading repos smooth landmarks over 12 frames at 25 fps.
    public static let minClipSeconds = 12 / Constants.mouthFps

    public enum Route: Sendable, Equatable {
        /// The mouth never moved.
        case nothingSeen
        /// The audio is clearly voiced, so Whisper should read it instead.
        case spokeAloud
        /// The mouth moved for less than `minClipSeconds`.
        case tooShort
        /// Lip-read the mouth frames inside this host-clock window. Nil ends mean the clip's own ends.
        case lipRead(start: Double?, end: Double?)
    }

    /// Where a silent dictation goes, from the mouth gate's result over the same clip.
    ///
    /// When the gate was bypassed because tracking dropped, the whole clip is read. The regions are
    /// unknown then, so only the audio can say it was spoken aloud.
    public static func route(_ gate: MouthGate.Result) -> Route {
        if gate.voicedRatio > aloudVoicedRatio { return .spokeAloud }
        if gate.bypassed { return .lipRead(start: nil, end: nil) }
        guard let first = gate.regions.first, let last = gate.regions.last else { return .nothingSeen }
        guard last.end - first.start >= minClipSeconds else { return .tooShort }
        return .lipRead(start: first.start, end: last.end)
    }

    /// True when the mouth crops were too dark for the model to read well.
    public static func isDark(meanLuma: Double?) -> Bool {
        guard let meanLuma else { return false }
        return meanLuma < TakeQuality.lowLightLuma
    }

    // MARK: LLM cleanup (Phase C)

    public static let cleanupInstructions = """
    You turn a lip-reading model's guesses into the sentence the user most likely mouthed. \
    The guesses come from silent video of the user's lips, ranked best first. \
    Lips look the same for p, b and m, for f and v, and for t, d and n, so the model often confuses them. \
    It also splits or joins words that sound alike. Prefer an everyday sentence that fits the app the user is typing in. \
    Stay close to the guesses and don't add ideas of your own. \
    Reply with the sentence only, with normal capitalisation and punctuation.
    """

    public static func cleanupPrompt(hypotheses: [String], appName: String?) -> String {
        var lines = ["App: \(appName ?? "unknown")", "Guesses:"]
        for (i, text) in hypotheses.enumerated() { lines.append("\(i + 1). \(text)") }
        return lines.joined(separator: "\n")
    }

    /// The LLM's sentence when it is usable, otherwise nil.
    ///
    /// It must be one line of text and no more than twice as many words as the longest guess, so a
    /// chatty or runaway reply never gets typed.
    public static func acceptCleanup(_ output: String?, hypotheses: [String]) -> String? {
        guard var text = output?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.count >= 2, text.first == "\"", text.last == "\"" { text = String(text.dropFirst().dropLast()) }
        guard !text.contains(where: \.isNewline) else { return nil }
        let longest = hypotheses.map { words($0).count }.max() ?? 0
        let count = words(text).count
        guard count > 0, count <= max(2 * longest, 2) else { return nil }
        return text
    }

    /// The top guess as typed text when there is no LLM: trimmed, with its first letter capitalised.
    public static func fallbackText(_ hypothesis: String) -> String {
        let text = hypothesis.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let first = text.first else { return "" }
        return first.uppercased() + text.dropFirst()
    }

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0.isWhitespace })
    }
}
