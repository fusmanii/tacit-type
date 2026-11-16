import Foundation

/// The Mac app's link to the lip-reading sidecar (`python -m silentml.serve`).
///
/// Newline-delimited JSON over a Unix socket. Each line is one request or one reply, and a reply
/// carries the `id` of its request. The sidecar handles one request at a time.
/// `ml/silentml/serve.py` mirrors these shapes, and `ml/tests/test_serve.py` reads the fixture that
/// `SidecarProtocolTests` writes.
public enum SidecarProtocol {
    public static let socketName = "sidecar.sock"
    /// `sockaddr_un.sun_path` holds 104 bytes on macOS, including the terminating zero.
    public static let maxSocketPathBytes = 103
    public static let defaultHypotheses = 5

    public static func encode(_ request: SidecarRequest) throws -> Data {
        var data = try encoder.encode(request)
        data.append(0x0A)
        return data
    }

    public static func decodeReply(_ line: Data) throws -> SidecarReply {
        try JSONDecoder().decode(SidecarReply.self, from: line)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

public struct SidecarRequest: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable {
        case health, transcribe
    }

    public var id: Int
    public var op: Op
    /// Session folder path. `transcribe` only.
    public var session: String?
    /// Host-clock window, seconds. Frames outside it are ignored. Nil means the clip's own start or end.
    public var start: Double?
    public var end: Double?
    /// How many hypotheses to return.
    public var n: Int?

    public static func health(id: Int) -> SidecarRequest {
        SidecarRequest(id: id, op: .health)
    }

    public static func transcribe(id: Int, session: URL, start: Double?, end: Double?,
                                  n: Int = SidecarProtocol.defaultHypotheses) -> SidecarRequest {
        SidecarRequest(id: id, op: .transcribe, session: session.path, start: start, end: end, n: n)
    }

    public init(id: Int, op: Op, session: String? = nil, start: Double? = nil, end: Double? = nil, n: Int? = nil) {
        self.id = id
        self.op = op
        self.session = session
        self.start = start
        self.end = end
        self.n = n
    }
}

/// Exactly one of `health`, `transcript` and `error` is set.
public struct SidecarReply: Codable, Sendable, Equatable {
    public struct Health: Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable {
            case loading, ready
        }

        public var state: State
        public var model: String
        public var beam: Int
        public var device: String
        /// Path of the checkpoint the sidecar loaded.
        public var checkpoint: String
        /// Path of the alignment correction in use. Nil when there is none.
        public var correction: String?
        /// When the correction was fitted, ISO 8601, as `alignment_correction.json` records it.
        public var correctionCreatedAt: String?
        public var protocolVersion: Int
        public var pid: Int

        public init(state: State, model: String, beam: Int, device: String, checkpoint: String,
                    correction: String?, correctionCreatedAt: String?, protocolVersion: Int, pid: Int) {
            self.state = state
            self.model = model
            self.beam = beam
            self.device = device
            self.checkpoint = checkpoint
            self.correction = correction
            self.correctionCreatedAt = correctionCreatedAt
            self.protocolVersion = protocolVersion
            self.pid = pid
        }
    }

    public struct Hypothesis: Codable, Sendable, Equatable {
        /// Lowercase, no punctuation.
        public var text: String
        /// The beam search's total log score.
        public var score: Double

        public init(text: String, score: Double) {
            self.text = text
            self.score = score
        }
    }

    /// Seconds spent inside the sidecar.
    public struct Timings: Codable, Sendable, Equatable {
        /// Reading the session folder.
        public var load: Double
        public var preprocess: Double
        public var decode: Double

        enum CodingKeys: String, CodingKey {
            case load = "load_s", preprocess = "preprocess_s", decode = "decode_s"
        }

        public init(load: Double, preprocess: Double, decode: Double) {
            self.load = load
            self.preprocess = preprocess
            self.decode = decode
        }

        public var total: Double { load + preprocess + decode }
    }

    public struct Transcript: Codable, Sendable, Equatable {
        /// Best first. Never empty.
        public var hypotheses: [Hypothesis]
        /// 25 fps frames the model read.
        public var frames: Int
        public var timings: Timings

        public init(hypotheses: [Hypothesis], frames: Int, timings: Timings) {
            self.hypotheses = hypotheses
            self.frames = frames
            self.timings = timings
        }
    }

    public struct Failure: Codable, Sendable, Equatable, Error {
        public enum Code: String, Codable, Sendable {
            /// Fewer frames in the window than the models need.
            case tooShort = "too_short"
            case noMouth = "no_mouth"
            case badSession = "bad_session"
            case badRequest = "bad_request"
            case notReady = "not_ready"
            case `internal`
        }

        public var code: Code
        public var message: String

        public init(code: Code, message: String) {
            self.code = code
            self.message = message
        }
    }

    public var id: Int
    public var health: Health?
    public var transcript: Transcript?
    public var error: Failure?

    public init(id: Int, health: Health? = nil, transcript: Transcript? = nil, error: Failure? = nil) {
        self.id = id
        self.health = health
        self.transcript = transcript
        self.error = error
    }
}
