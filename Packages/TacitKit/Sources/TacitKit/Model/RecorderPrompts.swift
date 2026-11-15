import Foundation

/// One thing the Recorder asks the user to do.
public struct RecorderPrompt: Sendable, Equatable {
    /// Goes into the manifest as `promptId`, for example `harvard-03-07`.
    public var promptId: String
    public var text: String
    public var style: SpeechStyle
    /// Seconds a normal take lasts. The duration check allows up to twice this.
    public var expectedDuration: Double
    /// Capture stops by itself after this many seconds.
    public var timeLimit: Double

    public init(promptId: String, text: String, style: SpeechStyle, expectedDuration: Double, timeLimit: Double? = nil) {
        self.promptId = promptId
        self.text = text
        self.style = style
        self.expectedDuration = expectedDuration
        self.timeLimit = timeLimit ?? 2 * expectedDuration
    }
}

public struct RecorderBlock: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case syncCheck, aloudSentences, whisperSentences, silentSentences, testSet, neutral
    }

    public var kind: Kind
    public var prompts: [RecorderPrompt]

    public var id: Kind { kind }

    public var title: String {
        switch kind {
        case .syncCheck: "Sync check"
        case .aloudSentences: "Aloud sentences"
        case .whisperSentences: "Whisper sentences"
        case .silentSentences: "Silent sentences"
        case .testSet: "Test set"
        case .neutral: "Neutral"
        }
    }
}

/// Builds the Recorder's blocks. A training sitting has the sync check, aloud and silent sentences and
/// the neutral takes. The test set runs once, in a sitting of its own, so it can be held out whole.
public enum RecorderPrompts {
    public static let sentencesPerSitting = 50
    /// Whispered takes per sitting. They test dictation and the mouth gate (M4), not lip-reading.
    public static let whisperPerSitting = 10
    public static let neutralTakes = 3
    public static let neutralDuration = 10.0

    public static let syncCheck = RecorderPrompt(promptId: "sync-pa", text: "pa pa pa pa pa", style: .aloud, expectedDuration: 3)

    /// Neutral face and the `MouthActivity` threshold. Saved with speech style `negative`.
    public static let neutral = RecorderPrompt(promptId: "neutral-still", text: "Stay still", style: .negative,
                                               expectedDuration: neutralDuration, timeLimit: neutralDuration)

    /// Parses the Harvard sentence file (`ml/prompts/harvard.txt`): one sentence per line, ten per list.
    /// Ids are `harvard-<list>-<sentence>`, both counted from 1.
    public static func harvardSentences(from text: String) -> [(id: String, text: String)] {
        lines(text).enumerated().map { index, sentence in
            (String(format: "harvard-%02d-%02d", index / 10 + 1, index % 10 + 1), sentence)
        }
    }

    /// Parses a plain prompt list (`ml/prompts/everyday.txt`, `test.txt`): one prompt per line.
    /// Ids are `<prefix>-<line>`, counted from 1, so a prompt keeps its id as long as the file only grows.
    public static func prompts(from text: String, prefix: String) -> [(id: String, text: String)] {
        lines(text).enumerated().map { index, sentence in (String(format: "\(prefix)-%04d", index + 1), sentence) }
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// About 0.4 s per word plus time to get going.
    public static func expectedDuration(forSentence sentence: String) -> Double {
        0.8 + 0.4 * Double(sentence.split(separator: " ").count)
    }

    private static func sentencePrompts(_ style: SpeechStyle, _ list: [(id: String, text: String)]) -> [RecorderPrompt] {
        list.map { RecorderPrompt(promptId: $0.id, text: $0.text, style: style, expectedDuration: expectedDuration(forSentence: $0.text)) }
    }

    /// The blocks of one training sitting.
    ///
    /// Sentences the user has not recorded yet come first, so sittings work through the whole corpus.
    /// The silent block repeats the aloud block's sentences in a new order, which gives every
    /// silent take an aloud partner. The whisper block whispers `whisperPerSitting` of them.
    public static func sitting(sentences: [(id: String, text: String)], alreadyRecorded: Set<String> = [],
                               using generator: inout some RandomNumberGenerator) -> [RecorderBlock] {
        let fresh = sentences.filter { !alreadyRecorded.contains($0.id) }.shuffled(using: &generator)
        let repeats = sentences.filter { alreadyRecorded.contains($0.id) }.shuffled(using: &generator)
        let picked = Array((fresh + repeats).prefix(sentencesPerSitting))
        return [
            RecorderBlock(kind: .syncCheck, prompts: [syncCheck]),
            RecorderBlock(kind: .aloudSentences, prompts: sentencePrompts(.aloud, picked)),
            RecorderBlock(kind: .whisperSentences,
                          prompts: sentencePrompts(.whisper, Array(picked.shuffled(using: &generator).prefix(whisperPerSitting)))),
            RecorderBlock(kind: .silentSentences, prompts: sentencePrompts(.silent, picked.shuffled(using: &generator))),
            RecorderBlock(kind: .neutral, prompts: Array(repeating: neutral, count: neutralTakes)),
        ]
    }

    /// The test-set sitting: a sync check, then every test prompt mouthed silently, in a fixed shuffle.
    public static func testSitting(prompts: [(id: String, text: String)],
                                   using generator: inout some RandomNumberGenerator) -> [RecorderBlock] {
        [
            RecorderBlock(kind: .syncCheck, prompts: [syncCheck]),
            RecorderBlock(kind: .testSet, prompts: sentencePrompts(.silent, prompts.shuffled(using: &generator))),
        ]
    }
}
