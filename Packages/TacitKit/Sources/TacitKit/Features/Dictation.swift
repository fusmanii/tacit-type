import Foundation

/// The pure parts of spoken and whisper dictation (Step 2). The Mac app's `DictationPipeline` wires
/// them around WhisperKit.
public enum DictationAudio {
    /// Whispers are quiet, so every clip is normalised to this peak before Whisper hears it.
    public static let targetPeakDb = -3.0
    /// A clip whose loudest 20 ms frame is under this, with the mouth gate open, was whispered.
    public static let whisperCeilingDb = -30.0

    /// Float32, DC offset removed, peak normalised to `targetPeakDb`. Silence stays silent.
    public static func prepare(_ samples: [Int16]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        var floats = samples.map { Float((Double($0) - mean) / 32_768) }
        let peak = floats.reduce(0) { max($0, abs($1)) }
        guard peak > 1e-6 else { return floats.map { _ in 0 } }
        let gain = Float(pow(10, targetPeakDb / 20)) / peak
        for i in floats.indices { floats[i] *= gain }
        return floats
    }

    /// The loudest 20 ms frame, dBFS, before any normalisation.
    public static func peakLevel(_ samples: [Int16]) -> Double {
        AudioLevel.frameLevels(samples).max() ?? AudioLevel.floorDb
    }

    /// `whisper` when the gate let speech through and the clip never got louder than `whisperCeilingDb`.
    public static func speechStyle(gatedAudio: [Int16]) -> SpeechStyle {
        peakLevel(gatedAudio) < whisperCeilingDb ? .whisper : .aloud
    }
}

public enum DictationText {
    /// What Whisper tends to say about silence or room noise.
    public static let hallucinations: Set<String> = [
        "thank you.", "thank you", "thanks for watching!", "thanks for watching.", "thanks for watching",
        "you", ".", "bye.", "bye",
    ]
    /// Clips shorter than this can only produce a blocklisted line by accident.
    public static let shortClip = 1.5
    /// Clips whose VAD speech is under this many seconds count as quiet.
    public static let quietSpeech = 0.5

    /// True when `text` is a known hallucination and the clip was short or quiet.
    public static func isHallucination(_ text: String, clipDuration: Double, speechDuration: Double) -> Bool {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hallucinations.contains(key) else { return false }
        return clipDuration < shortClip || speechDuration < quietSpeech
    }

    /// One user replacement, for example "new line" → "\n".
    public struct Replacement: Sendable, Equatable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// Parses Settings → Dictation → Replacements: one `from => to` per line. `\n` and `\t` in `to` are
    /// a newline and a tab. Lines without `=>` are ignored.
    public static func replacements(from text: String) -> [Replacement] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { return nil }
            let from = parts[0].trimmingCharacters(in: .whitespaces)
            let to = parts[1].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
            return from.isEmpty ? nil : Replacement(from: from, to: to)
        }
    }

    /// Parses Settings → Dictation → Words: one word or name per line or comma.
    public static func vocabulary(from text: String) -> [String] {
        text.split { $0.isNewline || $0 == "," }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Trims, collapses whitespace, then applies the replacements as whole, case-insensitive phrases.
    /// Punctuation Whisper put next to a replaced phrase goes with it, so "new line." gives one newline.
    /// Spaces around a newline or tab a replacement produced are dropped.
    public static func clean(_ text: String, replacements: [Replacement] = []) -> String {
        var result = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for replacement in replacements {
            let words = replacement.from.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = "(?<![\\p{L}\\p{N}])" + words.joined(separator: "[\\s,]+") + "(?![\\p{L}\\p{N}])[.,!?;:]?"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: replacement.to)
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        result = result.replacingOccurrences(of: " *([\\n\\t]) *", with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// Word error rate between a reference and a hypothesis, after both are normalised the way the
/// lip-reading labels are: lowercase, punctuation stripped, apostrophes kept.
public enum WordErrorRate {
    public static func normalise(_ text: String) -> [String] {
        let kept = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "'" ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").map(String.init)
    }

    /// Edits (substitutions + insertions + deletions) needed to turn `hypothesis` into `reference`.
    public static func edits(reference: [String], hypothesis: [String]) -> Int {
        guard !reference.isEmpty else { return hypothesis.count }
        guard !hypothesis.isEmpty else { return reference.count }
        var previous = Array(0 ... hypothesis.count)
        for (i, word) in reference.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: hypothesis.count)
            for (j, other) in hypothesis.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (word == other ? 0 : 1))
            }
            previous = current
        }
        return previous[hypothesis.count]
    }

    /// Nil when the reference has no words.
    public static func wer(reference: String, hypothesis: String) -> Double? {
        let ref = normalise(reference)
        guard !ref.isEmpty else { return nil }
        return Double(edits(reference: ref, hypothesis: normalise(hypothesis))) / Double(ref.count)
    }

    /// Corpus WER: total edits over total reference words, so long prompts weigh more.
    public static func corpus(_ pairs: [(reference: String, hypothesis: String)]) -> Double? {
        var edits = 0
        var words = 0
        for pair in pairs {
            let ref = normalise(pair.reference)
            edits += Self.edits(reference: ref, hypothesis: normalise(pair.hypothesis))
            words += ref.count
        }
        return words == 0 ? nil : Double(edits) / Double(words)
    }
}
