import Darwin
import Foundation
import Testing
@testable import TacitKit

/// Requests and replies that `ml/tests/test_serve.py` reads back, so the Swift and Python sides of the
/// sidecar protocol can't drift.
enum SidecarFixture {
    static let folder = SessionFixture.root.deletingLastPathComponent().appending(path: "sidecar")
    static let requestsURL = folder.appending(path: "requests.jsonl")
    static let repliesURL = folder.appending(path: "replies.jsonl")

    static let requests: [SidecarRequest] = [
        .health(id: 1),
        .transcribe(id: 2, session: URL(filePath: "/tmp/tacit/2026-11-05/0A1B2C3D-0000-4000-8000-000000000001"),
                    start: 81_234.75, end: 81_239.5),
        .transcribe(id: 3, session: URL(filePath: "/tmp/tacit/s"), start: nil, end: nil, n: 1),
    ]

    static let replies: [SidecarReply] = [
        SidecarReply(id: 1, health: .init(state: .ready, model: "auto-avsr", beam: 10, device: "mps",
                                          checkpoint: "/models/vsr_trlrs2lrs3vox2avsp_base.pth",
                                          correction: "/models/alignment_correction.json",
                                          correctionCreatedAt: "2026-11-16T01:51:50+00:00",
                                          protocolVersion: Constants.sidecarProtocolVersion, pid: 4242)),
        SidecarReply(id: 1, health: .init(state: .loading, model: "auto-avsr", beam: 10, device: "cpu",
                                          checkpoint: "/models/x.pth", correction: nil, correctionCreatedAt: nil,
                                          protocolVersion: Constants.sidecarProtocolVersion, pid: 7)),
        SidecarReply(id: 2, transcript: .init(
            hypotheses: [.init(text: "a small creek cut across the field", score: -3.25),
                         .init(text: "a small cricket across the field", score: -4.5)],
            frames: 119, timings: .init(load: 0.0625, preprocess: 0.125, decode: 0.5))),
        SidecarReply(id: 3, error: .init(code: .tooShort, message: "clip has 5 frames, the models need at least 12")),
    ]

    static func lines<T: Encodable>(_ values: [T]) throws -> Data {
        var data = Data()
        for value in values {
            data.append(try SidecarProtocol.encoder.encode(value))
            data.append(0x0A)
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        try Data(contentsOf: url).split(separator: 0x0A).map { try JSONDecoder().decode(T.self, from: Data($0)) }
    }
}

@Suite("Sidecar protocol")
struct SidecarProtocolTests {
    @Test func requestsEncodeAsOneLineWithOnlyTheirFields() throws {
        let line = try SidecarProtocol.encode(.health(id: 9))
        #expect(String(decoding: line, as: UTF8.self) == "{\"id\":9,\"op\":\"health\"}\n")
        let transcribe = try SidecarProtocol.encode(SidecarFixture.requests[1])
        #expect(transcribe.last == 0x0A)
        #expect(!transcribe.dropLast().contains(0x0A))
    }

    @Test func repliesRoundTrip() throws {
        for reply in SidecarFixture.replies {
            let data = try SidecarProtocol.encoder.encode(reply)
            #expect(try SidecarProtocol.decodeReply(data) == reply)
        }
    }

    @Test func timingsUseTheSnakeCaseKeys() throws {
        let json = String(decoding: try SidecarProtocol.encoder.encode(SidecarFixture.replies[2]), as: UTF8.self)
        #expect(json.contains("\"preprocess_s\":0.125"))
    }

    @Test func unknownErrorCodesFailToDecode() {
        let line = Data(#"{"id":1,"error":{"code":"nope","message":"x"}}"#.utf8)
        #expect(throws: DecodingError.self) { try SidecarProtocol.decodeReply(line) }
    }

    /// Fails when the protocol changes without the Python fixture being regenerated.
    /// Regenerate with `TACIT_WRITE_FIXTURE=1 make test-swift`, then fix `ml/tests/test_serve.py`.
    @Test func fixtureForPythonIsCurrent() throws {
        if ProcessInfo.processInfo.environment["TACIT_WRITE_FIXTURE"] != nil {
            try FileManager.default.createDirectory(at: SidecarFixture.folder, withIntermediateDirectories: true)
            try SidecarFixture.lines(SidecarFixture.requests).write(to: SidecarFixture.requestsURL)
            try SidecarFixture.lines(SidecarFixture.replies).write(to: SidecarFixture.repliesURL)
        }
        #expect(try SidecarFixture.decode(SidecarRequest.self, from: SidecarFixture.requestsURL) == SidecarFixture.requests,
                "requests.jsonl in ml/tests/fixtures/sidecar is stale")
        #expect(try SidecarFixture.decode(SidecarReply.self, from: SidecarFixture.repliesURL) == SidecarFixture.replies,
                "replies.jsonl in ml/tests/fixtures/sidecar is stale")
    }
}

/// A one-connection Unix socket server that answers with a canned line.
private final class FakeSidecar: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private(set) var received = Data()

    init(reply: @escaping @Sendable (Data) -> Data?) throws {
        path = "/tmp/tacit-test-\(UUID().uuidString.prefix(8)).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        fd = listener
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw SidecarClientError.ioFailed(errno) }
        Thread.detachNewThread { [self] in
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var line = Data()
            while !line.contains(0x0A) {
                let n = recv(client, &buffer, buffer.count, 0)
                if n <= 0 { return }
                line.append(contentsOf: buffer[..<n])
            }
            received = line
            guard let out = reply(line) else {
                Thread.sleep(forTimeInterval: 1)
                return
            }
            _ = out.withUnsafeBytes { Darwin.send(client, $0.baseAddress!, $0.count, 0) }
        }
    }

    deinit {
        close(fd)
        unlink(path)
    }
}

@Suite("Sidecar client")
struct SidecarClientTests {
    @Test func sendsALineAndReadsTheReply() async throws {
        let server = try FakeSidecar { _ in
            try? SidecarFixture.lines([SidecarFixture.replies[2]])
        }
        let reply = try await SidecarClient(socketPath: server.path)
            .send(SidecarFixture.requests[1], timeout: .seconds(2))
        #expect(reply == SidecarFixture.replies[2])
        #expect(try JSONDecoder().decode(SidecarRequest.self, from: server.received.dropLast()) == SidecarFixture.requests[1])
    }

    @Test func aReplyForAnotherRequestIsRejected() async throws {
        let server = try FakeSidecar { _ in try? SidecarFixture.lines([SidecarFixture.replies[0]]) }
        await #expect(throws: SidecarClientError.mismatchedReply(expected: 2, got: 1)) {
            try await SidecarClient(socketPath: server.path).send(SidecarFixture.requests[1], timeout: .seconds(2))
        }
    }

    @Test func aSilentSidecarTimesOut() async throws {
        let server = try FakeSidecar { _ in nil }
        await #expect(throws: SidecarClientError.timedOut) {
            try await SidecarClient(socketPath: server.path).send(.health(id: 1), timeout: .milliseconds(200))
        }
    }

    @Test func noSidecarFailsToConnect() async {
        await #expect(throws: SidecarClientError.connectFailed(ENOENT)) {
            try await SidecarClient(socketPath: "/tmp/tacit-missing.sock").send(.health(id: 1), timeout: .seconds(1))
        }
    }
}

@Suite("Silent dictation")
struct SilentDictationTests {
    private func gate(regions: [MouthGate.Region], voiced: Double = 0.05, bypassed: Bool = false) -> MouthGate.Result {
        MouthGate.Result(decision: .silentMouthing, regions: regions, bypassed: bypassed, voicedRatio: voiced, gatedOutSeconds: 0)
    }

    @Test func routesSilentMouthingToTheLipReaderWithItsWindow() {
        let route = SilentDictation.route(gate(regions: [.init(start: 10, end: 11), .init(start: 12, end: 13.5)]))
        #expect(route == .lipRead(start: 10, end: 13.5))
    }

    @Test func routesVoicedSpeechToWhisper() {
        #expect(SilentDictation.route(gate(regions: [.init(start: 10, end: 12)], voiced: 0.8)) == .spokeAloud)
        #expect(SilentDictation.route(gate(regions: [], voiced: 0.8, bypassed: true)) == .spokeAloud)
    }

    @Test func aStillMouthOrABlipIsNothing() {
        #expect(SilentDictation.route(gate(regions: [])) == .nothingSeen)
        #expect(SilentDictation.route(gate(regions: [.init(start: 10, end: 10.4)])) == .tooShort)
    }

    @Test func aBypassedGateReadsTheWholeClip() {
        #expect(SilentDictation.route(gate(regions: [], bypassed: true)) == .lipRead(start: nil, end: nil))
    }

    @Test func cleanupAcceptsAShortSentenceAndRejectsChatter() {
        let guesses = ["a small cricket across the field", "a small creek across the field"]
        #expect(SilentDictation.acceptCleanup(" \"A small creek cut across the field.\" ", hypotheses: guesses)
            == "A small creek cut across the field.")
        #expect(SilentDictation.acceptCleanup("", hypotheses: guesses) == nil)
        #expect(SilentDictation.acceptCleanup(nil, hypotheses: guesses) == nil)
        #expect(SilentDictation.acceptCleanup("Sure!\nA small creek.", hypotheses: guesses) == nil)
        let long = Array(repeating: "word", count: 13).joined(separator: " ")
        #expect(SilentDictation.acceptCleanup(long, hypotheses: guesses) == nil)
    }

    @Test func fallbackCapitalisesTheTopGuess() {
        #expect(SilentDictation.fallbackText("  running ten  minutes late ") == "Running ten minutes late")
        #expect(SilentDictation.fallbackText("") == "")
    }

    @Test func promptListsTheGuessesInOrder() {
        let prompt = SilentDictation.cleanupPrompt(hypotheses: ["one", "two"], appName: "Slack")
        #expect(prompt == "App: Slack\nGuesses:\n1. one\n2. two")
    }

    @Test func darkCropsAreFlagged() {
        #expect(SilentDictation.isDark(meanLuma: 30))
        #expect(!SilentDictation.isDark(meanLuma: 110))
        #expect(!SilentDictation.isDark(meanLuma: nil))
    }
}
