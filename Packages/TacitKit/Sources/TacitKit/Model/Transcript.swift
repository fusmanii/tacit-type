import Foundation

/// `transcript.json` in a session folder. Written by the label job (with word timings) or by live
/// dictation (text only). Read by `ml/silentml/data.py`.
public struct Transcript: Codable, Sendable, Equatable {
    public struct Word: Codable, Sendable, Equatable {
        public var w: String
        /// Seconds from `firstAudioTs`, the first sample of `audio.wav`.
        public var start: Double
        public var end: Double
        /// Whisper's probability for the word, 0 … 1.
        public var p: Double

        public init(w: String, start: Double, end: Double, p: Double) {
            self.w = w
            self.start = start
            self.end = end
            self.p = p
        }
    }

    public var text: String
    /// Empty when the transcript came from live dictation.
    public var words: [Word]
    /// WhisperKit model id, for example `openai_whisper-small.en`.
    public var model: String
    public var createdAt: Date
    /// Word error rate against the manifest's `promptText`. Nil outside the Recorder.
    public var wer: Double?

    public init(text: String, words: [Word] = [], model: String, createdAt: Date, wer: Double? = nil) {
        self.text = text
        self.words = words
        self.model = model
        self.createdAt = createdAt
        self.wer = wer
    }

    /// Above this WER against the prompt, the take is flagged `transcript_mismatch`.
    public static let maxPromptWer = 0.3
}
