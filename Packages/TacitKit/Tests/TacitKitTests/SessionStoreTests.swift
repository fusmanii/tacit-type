import Foundation
import Testing
@testable import TacitKit

/// The synthetic sessions behind `ml/tests/fixtures/sessions`. `ml/tests/test_data.py` rebuilds
/// the same values in Python and checks every field, so the two sides can't drift.
enum SessionFixture {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "ml/tests/fixtures/sessions")

    static let faceT0 = 81_234.512
    static let audioT0 = 81_234.498

    static func frame(_ i: Int, tracked: Bool = true) -> FaceFrame {
        let timestamp = faceT0 + Double(i) / 60
        guard tracked else { return .untracked(at: timestamp) }
        return FaceFrame(
            timestamp: timestamp,
            trackingFlags: [.isTracked, .trackingNormal],
            blendShapes: (0 ..< Constants.blendShapeCount).map { Float(i * 100 + $0) / 1000 },
            headTransform: (0 ..< 16).map { Float($0 - i) / 8 },
            lipVertices: (0 ..< Constants.lipVertexCount).map {
                SIMD3(Float($0) / 1000, Float(i) / 1000, Float($0 * i) / -1000)
            }
        )
    }

    static func audio(count: Int) -> [Int16] {
        (0 ..< count).map { Int16(($0 * 37) % 2001 - 1000) }
    }

    static var aloud: StoredSession {
        let frames = (0 ..< 12).map { frame($0, tracked: $0 != 5) }
        let manifest = SessionManifest(
            sessionId: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1_793_836_800), // 2026-11-05T00:00:00Z
            mode: .record, speechStyle: .aloud,
            promptId: "harvard-03-07", promptText: "The birch canoe slid on the smooth planks.",
            sittingId: UUID(uuidString: "0A1B2C3D-0000-4000-8000-0000000000AA")!,
            device: .init(model: "iPhone16,1", osVersion: "18.2"),
            appVersions: .init(mac: "0.1.0", iphone: "0.1.0"),
            protocolVersion: 1, featureSchemaVersion: 1,
            firstFaceTs: faceT0, firstAudioTs: audioT0,
            frameCount: frames.count, measuredFps: 60, trackedRatio: 11.0 / 12,
            droppedFrames: 0, audioGapsFilled: 1, measuredAvOffsetMs: -4.5,
            mouthFrameCount: 5, mouthFps: 25, meanLuma: 111.5,
            quality: .init(ok: true)
        )
        return StoredSession(manifest: manifest, frames: frames, audio: audio(count: 3_200), mouth: mouth)
    }

    static let mouthT0 = 81_234.52

    /// A smooth gradient that brightens 10 levels a frame, so H.264 keeps it within a level or two.
    static func mouthPixels(_ k: Int) -> [UInt8] { gradientFrame(step: 10 * k) }

    static func mouthLandmarks(_ k: Int) -> [SIMD2<Float>] {
        (0 ..< Constants.cropLandmarkCount).map { SIMD2(Float($0 * 10 + k), Float($0 * 5) - 20.5) }
    }

    static let mouth: [MouthFrame] = (0 ..< 5).map { k in
        MouthFrame(timestamp: mouthT0 + Double(k) * 0.04, landmarks: mouthLandmarks(k), jpeg: try! MouthJPEG.encode(mouthPixels(k)))
    }

    /// A flagged silent take with every optional field left out.
    static var flaggedSilent: StoredSession {
        let manifest = SessionManifest(
            sessionId: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 1_793_836_860),
            mode: .silent, speechStyle: .silent,
            device: .init(model: "iPhone16,1", osVersion: "18.2"),
            appVersions: .init(mac: "0.1.0", iphone: "0.1.0"),
            frameCount: 3, measuredFps: 60, trackedRatio: 1,
            quality: .init(ok: false, flags: ["audible_in_silent", "too_short"])
        )
        return StoredSession(manifest: manifest, frames: (0 ..< 3).map { frame($0) }, audio: audio(count: 160))
    }

    static let all = [aloud, flaggedSilent]
}

@Suite("Session store")
struct SessionStoreTests {
    private func temporaryStore() -> SessionStore {
        SessionStore(root: FileManager.default.temporaryDirectory.appending(path: "tacit-tests-\(UUID().uuidString)"),
                     timeZone: .gmt)
    }

    @Test func faceFileHeaderIsAsSpecced() throws {
        let data = try FaceFile.encode(SessionFixture.aloud.frames)
        #expect(data.count == 16 + 12 * 1_052)
        #expect(Array(data.prefix(12)) == [0x53, 0x46, 0x43, 0x45, 1, 0, 64, 0, 12, 0, 0, 0])
        #expect(try FaceFile.decode(data) == SessionFixture.aloud.frames)
    }

    @Test func faceFileRejectsOtherSchemas() throws {
        var data = try FaceFile.encode([])
        data[4] = 2
        #expect(throws: SessionFileError.schemaMismatch(found: 2)) { try FaceFile.decode(data) }
        data[0] = 0
        #expect(throws: SessionFileError.badMagic) { try FaceFile.decode(data) }
        #expect(throws: SessionFileError.lengthMismatch) { try FaceFile.decode(try FaceFile.encode([]) + [0]) }
    }

    @Test func wavRoundTrips() throws {
        let samples: [Int16] = [0, 1, -1, .max, .min, 12_345]
        let data = WavFile.encode(samples)
        #expect(data.count == 44 + 12)
        let decoded = try WavFile.decode(data)
        #expect(decoded.samples == samples)
        #expect(decoded.sampleRate == 16_000)
    }

    @Test func writesAndReadsSessionFolders() async throws {
        let store = temporaryStore()
        defer { try? store.deleteAll() }
        for session in SessionFixture.all {
            let folder = try await store.write(session)
            #expect(folder.path.hasSuffix("2026-11-05/\(session.manifest.sessionId.uuidString)"))
            var withoutMouth = session
            withoutMouth.mouth = []
            #expect(try store.read(at: folder) == withoutMouth)

            let mouth = try await store.readMouth(at: folder)
            if session.mouth.isEmpty {
                #expect(mouth == nil)
                #expect(!FileManager.default.fileExists(atPath: folder.appending(path: SessionStore.mouthVideoName).path))
            } else {
                let track = try #require(mouth)
                #expect(track.records.map(\.timestamp) == session.mouth.map(\.timestamp))
                #expect(track.records.map(\.landmarks) == session.mouth.map(\.landmarks))
                for (k, pixels) in track.pixels.enumerated() {
                    let error = zip(pixels, SessionFixture.mouthPixels(k)).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                    #expect(Double(error) / Double(pixels.count) < 2.5)
                }
            }
        }
        #expect(store.sessionFolders().count == 2)
        #expect(store.manifests() == SessionFixture.all.map(\.manifest))
        #expect(store.diskUsage() > 12 * 1_052)
        try store.deleteAll()
        #expect(store.sessionFolders().isEmpty)
    }

    /// Fails when the on-disk format changes without the Python fixture being regenerated.
    /// Regenerate with `TACIT_WRITE_FIXTURE=1 make test-swift`, then fix `ml/tests/test_data.py`.
    /// `mouth.mp4` is compared by decoded frame count, since encoder output can differ between macOS versions.
    @Test func fixtureForPythonIsCurrent() async throws {
        if ProcessInfo.processInfo.environment["TACIT_WRITE_FIXTURE"] != nil {
            let store = SessionStore(root: SessionFixture.root, timeZone: .gmt)
            try store.deleteAll()
            for session in SessionFixture.all { try await store.write(session) }
        }
        let store = temporaryStore()
        defer { try? store.deleteAll() }
        for session in SessionFixture.all {
            let written = try await store.write(session)
            let committed = SessionStore(root: SessionFixture.root, timeZone: .gmt).folder(for: session.manifest)
            // JSON formatting can differ between Foundation versions, so the manifest is compared by value.
            #expect(try SessionStore(root: SessionFixture.root).readManifest(at: committed) == session.manifest,
                    "manifest.json in ml/tests/fixtures is stale")
            let names = [SessionStore.faceName, SessionStore.audioName] + (session.mouth.isEmpty ? [] : [SessionStore.mouthName])
            for name in names {
                let expected = try Data(contentsOf: written.appending(path: name))
                let actual = try? Data(contentsOf: committed.appending(path: name))
                #expect(actual == expected, "\(name) in ml/tests/fixtures is stale")
            }
            let committedMouth = try await SessionStore(root: SessionFixture.root).readMouth(at: committed)
            #expect(committedMouth?.pixels.count == (session.mouth.isEmpty ? nil : session.mouth.count),
                    "mouth.mp4 in ml/tests/fixtures is stale")
        }
    }
}

@Suite("Take quality")
struct TakeQualityTests {
    private func metrics(tracked: Double = 1, fps: Double = 60) -> CaptureMetrics {
        var metrics = CaptureMetrics()
        metrics.trackedRatio = tracked
        metrics.measuredFps = fps
        return metrics
    }

    /// `seconds` of a 200 Hz tone at `db` dBFS RMS.
    private func tone(_ seconds: Double, db: Double) -> [Int16] {
        let peak = pow(10, db / 20) * 2.0.squareRoot() * 32_768
        return (0 ..< Int(seconds * 16_000)).map { Int16(peak * sin(2 * .pi * 200 * Double($0) / 16_000)) }
    }

    private func silence(_ seconds: Double) -> [Int16] { Array(repeating: 0, count: Int(seconds * 16_000)) }

    @Test func frameLevelsAreRmsDbfs() {
        let levels = AudioLevel.frameLevels(tone(0.1, db: -20) + silence(0.05))
        #expect(levels.count == 7)
        #expect(abs(levels[0] + 20) < 0.1)
        #expect(levels[6] == AudioLevel.floorDb)
    }

    @Test func cleanAloudTakePasses() {
        let audio = silence(0.5) + tone(1, db: -25) + silence(0.5)
        #expect(TakeQuality.flags(metrics: metrics(), audio: audio, style: .aloud, duration: 2, expectedDuration: 3).isEmpty)
        #expect(TakeQuality.quality([]).ok)
    }

    @Test func quietWhisperOverHissCountsAsSpeech() {
        var generator = SystemRandomNumberGenerator()
        let hiss = (0 ..< 32_000).map { _ in Int16.random(in: -6 ... 6, using: &generator) }
        var audio = hiss
        for (i, sample) in tone(0.6, db: -48).enumerated() { audio[8_000 + i] += sample }
        #expect(AudioLevel.speechDuration(audio) >= 0.5)
        #expect(AudioLevel.speechDuration(hiss) == 0)
    }

    @Test func flagsEachProblem() {
        let quiet = silence(2)
        #expect(TakeQuality.flags(metrics: metrics(), audio: quiet, style: .aloud, duration: 2, expectedDuration: 3) == [.noSpeech])
        #expect(TakeQuality.flags(metrics: metrics(tracked: 0.9), audio: quiet, style: .silent, duration: 2, expectedDuration: 3) == [.poorTracking])
        #expect(TakeQuality.flags(metrics: metrics(fps: 50), audio: quiet, style: .negative, duration: 2, expectedDuration: 3) == [.poorTracking])
        #expect(TakeQuality.flags(metrics: metrics(), audio: quiet, style: .silent, duration: 0.3, expectedDuration: 3) == [.tooShort])
        #expect(TakeQuality.flags(metrics: metrics(), audio: quiet, style: .silent, duration: 6.1, expectedDuration: 3) == [.tooLong])

        let murmur = silence(1) + tone(0.4, db: -35) + silence(1)
        #expect(TakeQuality.flags(metrics: metrics(), audio: murmur, style: .silent, duration: 2, expectedDuration: 3) == [.audibleInSilent])
        let click = silence(1) + tone(0.2, db: -35) + silence(1)
        #expect(TakeQuality.flags(metrics: metrics(), audio: click, style: .silent, duration: 2, expectedDuration: 3).isEmpty)

        let quality = TakeQuality.quality([.audibleInSilent, .tooShort])
        #expect(!quality.ok)
        #expect(quality.flags == ["audible_in_silent", "too_short"])
    }
}

@Suite("Sync check")
struct SyncCheckTests {
    /// Five "pa" bursts. The jaw opens as a bump at each burst, and the sound is shifted by `audioDelay`.
    private func take(audioDelay: Double, fps: Double = 60) -> (frames: [FaceFrame], audio: [Int16], audioT0: Double) {
        let start = 5_000.0
        let length = 3.5
        let centres = (0 ..< 5).map { 0.6 + 0.55 * Double($0) }
        func bump(_ t: Double) -> Double {
            centres.reduce(0) { $0 + exp(-pow((t - $1) / 0.06, 2)) }
        }
        let jaw = Constants.blendShapeOrder.firstIndex(of: "jawOpen")!
        let frames = (0 ..< Int(length * fps)).map { i -> FaceFrame in
            var frame = FaceFrame.untracked(at: start + Double(i) / fps)
            frame.trackingFlags = [.isTracked, .trackingNormal]
            frame.blendShapes[jaw] = Float(0.05 + 0.6 * bump(Double(i) / fps))
            return frame
        }
        let audioT0 = start - 0.014
        let audio = (0 ..< Int(length * 16_000)).map { n -> Int16 in
            let t = audioT0 + Double(n) / 16_000 - start - audioDelay
            return Int16(12_000 * bump(t) * sin(2 * .pi * 180 * Double(n) / 16_000))
        }
        return (frames, audio, audioT0)
    }

    @Test(arguments: [0, 0.004, -0.013, 0.037, -0.085]) func recoversKnownLag(delay: Double) throws {
        let take = take(audioDelay: delay)
        let result = try #require(SyncCheck.measure(frames: take.frames, audio: take.audio, audioT0: take.audioT0))
        #expect(abs(result.lagMs - delay * 1000) < 2)
        #expect(result.correlation > 0.9)
        #expect(result.passed == (abs(delay) < 0.02))
    }

    @Test func noResultWithoutACommonSignal() {
        let take = take(audioDelay: 0)
        #expect(SyncCheck.measure(frames: take.frames, audio: Array(repeating: 0, count: take.audio.count), audioT0: take.audioT0) == nil)
        #expect(SyncCheck.measure(frames: Array(take.frames.prefix(30)), audio: take.audio, audioT0: take.audioT0) == nil)
        #expect(SyncCheck.measure(frames: [], audio: take.audio, audioT0: take.audioT0) == nil)
    }
}

@Suite("Recorder prompts")
struct RecorderPromptTests {
    private let sentences = RecorderPrompts.harvardSentences(
        from: (0 ..< 720).map { "Sentence number \($0) goes here." }.joined(separator: "\n") + "\n")

    private static let promptsFolder = SessionFixture.root.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "prompts")

    @Test func harvardIdsCountListsAndSentences() {
        #expect(sentences.count == 720)
        #expect(sentences[0].id == "harvard-01-01")
        #expect(sentences[26].id == "harvard-03-07")
        #expect(sentences[719].id == "harvard-72-10")
    }

    @Test func bundledHarvardFileHas720Sentences() throws {
        let file = Self.promptsFolder.appending(path: "harvard.txt")
        let parsed = RecorderPrompts.harvardSentences(from: try String(contentsOf: file, encoding: .utf8))
        #expect(parsed.count == 720)
        #expect(parsed[0].text == "The birch canoe slid on the smooth planks.")
        #expect(Set(parsed.map(\.text)).count == 720)
    }

    @Test func plainPromptListsSkipCommentsAndBlanks() {
        let parsed = RecorderPrompts.prompts(from: "# everyday prompts\nrunning ten minutes late\n\n  sounds good, ship it  \n", prefix: "everyday")
        #expect(parsed.map(\.id) == ["everyday-0001", "everyday-0002"])
        #expect(parsed.map(\.text) == ["running ten minutes late", "sounds good, ship it"])
    }

    @Test func trainingSittingHasItsFourBlocks() {
        var generator = SystemRandomNumberGenerator()
        let blocks = RecorderPrompts.sitting(sentences: sentences, using: &generator)
        #expect(blocks.map(\.kind) == [.syncCheck, .aloudSentences, .silentSentences, .neutral])
        #expect(blocks.map(\.prompts.count) == [1, 50, 50, 3])

        #expect(blocks[1].prompts.allSatisfy { $0.style == .aloud })
        #expect(blocks[2].prompts.allSatisfy { $0.style == .silent })
        #expect(Set(blocks[1].prompts.map(\.promptId)) == Set(blocks[2].prompts.map(\.promptId)))
        #expect(Set(blocks[1].prompts.map(\.promptId)).count == 50)
        #expect(blocks[3].prompts.allSatisfy { $0.style == .negative && $0.timeLimit == 10 && $0.promptId == "neutral-still" })
    }

    @Test func testSittingIsSilentAndComplete() {
        var generator = SystemRandomNumberGenerator()
        let prompts = (1 ... 100).map { (id: String(format: "test-%04d", $0), text: "Test prompt \($0)") }
        let blocks = RecorderPrompts.testSitting(prompts: prompts, using: &generator)
        #expect(blocks.map(\.kind) == [.syncCheck, .testSet])
        #expect(blocks[1].prompts.count == 100)
        #expect(blocks[1].prompts.allSatisfy { $0.style == .silent })
        #expect(Set(blocks[1].prompts.map(\.promptId)) == Set(prompts.map(\.id)))
    }

    @Test func unrecordedSentencesComeFirst() {
        var generator = SystemRandomNumberGenerator()
        let recorded = Set(sentences.dropLast(30).map(\.id))
        let blocks = RecorderPrompts.sitting(sentences: sentences, alreadyRecorded: recorded, using: &generator)
        let picked = Set(blocks[1].prompts.map(\.promptId))
        #expect(picked.count == 50)
        #expect(picked.isSuperset(of: sentences.suffix(30).map(\.id)))
    }
}
