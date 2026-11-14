import Foundation

/// One thing the Recorder asks the user to do.
public struct RecorderPrompt: Sendable, Equatable {
    /// Goes into the manifest as `promptId`, for example `harvard-03-07`.
    public var promptId: String
    public var text: String
    public var style: SpeechStyle
    /// Only for command takes.
    public var commandId: String?
    /// Seconds a normal take lasts. The duration check allows up to twice this.
    public var expectedDuration: Double
    /// Capture stops by itself after this many seconds.
    public var timeLimit: Double

    public init(promptId: String, text: String, style: SpeechStyle, commandId: String? = nil,
                expectedDuration: Double, timeLimit: Double? = nil) {
        self.promptId = promptId
        self.text = text
        self.style = style
        self.commandId = commandId
        self.expectedDuration = expectedDuration
        self.timeLimit = timeLimit ?? 2 * expectedDuration
    }
}

public struct RecorderBlock: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case syncCheck, aloudSentences, silentSentences, commands, negatives
    }

    public var kind: Kind
    public var prompts: [RecorderPrompt]

    public var id: Kind { kind }

    public var title: String {
        switch kind {
        case .syncCheck: "Sync check"
        case .aloudSentences: "Aloud sentences"
        case .silentSentences: "Silent sentences"
        case .commands: "Commands"
        case .negatives: "Negatives"
        }
    }
}

/// Builds the five Recorder blocks for one sitting.
public enum RecorderPrompts {
    public static let sentencesPerSitting = 50
    public static let silentTakesPerCommand = 10
    public static let aloudTakesPerCommand = 3
    public static let negativeDuration = 10.0

    /// Step 3's starter set. The Commands block uses it until the user has their own list (M5).
    public static let starterCommands = [
        "send", "undo", "copy", "paste", "next", "back", "scroll up", "scroll down", "new tab", "close tab",
        "play", "pause", "mute", "volume up", "volume down", "screenshot", "yes", "no", "dictate", "lock",
    ]

    public static let negatives: [(id: String, text: String)] = [
        ("negative-talk", "Talk normally about anything"),
        ("negative-chew", "Chew"),
        ("negative-smile", "Smile"),
        ("negative-yawn", "Yawn"),
        ("negative-still", "Stay still"),
    ]

    public static let syncCheck = RecorderPrompt(promptId: "sync-pa", text: "pa pa pa pa pa", style: .aloud, expectedDuration: 3)

    /// Parses the Harvard sentence file: one sentence per line, ten per list.
    /// Ids are `harvard-<list>-<sentence>`, both counted from 1.
    public static func harvardSentences(from text: String) -> [(id: String, text: String)] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, sentence in
                (String(format: "harvard-%02d-%02d", index / 10 + 1, index % 10 + 1), sentence)
            }
    }

    /// `scroll up` → `scroll-up`
    public static func commandId(for phrase: String) -> String {
        phrase.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
    }

    /// About 0.4 s per word plus time to get going.
    public static func expectedDuration(forSentence sentence: String) -> Double {
        0.8 + 0.4 * Double(sentence.split(separator: " ").count)
    }

    /// The blocks for one sitting.
    ///
    /// Sentences the user has not recorded yet come first, so sittings work through all 720.
    /// The silent block repeats the aloud block's sentences in a new order, which gives every
    /// silent take an aloud partner. Commands run in rounds, each a fresh shuffle of the whole list.
    public static func sitting(sentences: [(id: String, text: String)], commands: [String] = starterCommands,
                               alreadyRecorded: Set<String> = [],
                               using generator: inout some RandomNumberGenerator) -> [RecorderBlock] {
        let fresh = sentences.filter { !alreadyRecorded.contains($0.id) }.shuffled(using: &generator)
        let repeats = sentences.filter { alreadyRecorded.contains($0.id) }.shuffled(using: &generator)
        let picked = Array((fresh + repeats).prefix(sentencesPerSitting))

        func sentencePrompts(_ style: SpeechStyle, _ list: [(id: String, text: String)]) -> [RecorderPrompt] {
            list.map { RecorderPrompt(promptId: $0.id, text: $0.text, style: style,
                                      expectedDuration: expectedDuration(forSentence: $0.text)) }
        }

        var commandPrompts: [RecorderPrompt] = []
        for (style, rounds) in [(SpeechStyle.silent, silentTakesPerCommand), (.aloud, aloudTakesPerCommand)] {
            for _ in 0 ..< rounds {
                commandPrompts += commands.shuffled(using: &generator).map { phrase in
                    let id = commandId(for: phrase)
                    return RecorderPrompt(promptId: "command-\(id)", text: phrase, style: style, commandId: id, expectedDuration: 1.5)
                }
            }
        }

        return [
            RecorderBlock(kind: .syncCheck, prompts: [syncCheck]),
            RecorderBlock(kind: .aloudSentences, prompts: sentencePrompts(.aloud, picked)),
            RecorderBlock(kind: .silentSentences, prompts: sentencePrompts(.silent, picked.shuffled(using: &generator))),
            RecorderBlock(kind: .commands, prompts: commandPrompts),
            RecorderBlock(kind: .negatives, prompts: negatives.map {
                RecorderPrompt(promptId: $0.id, text: $0.text, style: .negative,
                               expectedDuration: negativeDuration, timeLimit: negativeDuration)
            }),
        ]
    }
}
