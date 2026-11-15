import Foundation
import Testing
@testable import TacitKit

/// Synthetic takes for the mouth gate: 60 fps face frames whose jaw moves inside `moving`, and
/// 16 kHz audio that holds a −20 dBFS tone inside `voiced`. Face and audio both start at `t0`.
private enum GateFixture {
    static let t0 = 100.0
    static let jaw = Constants.blendShapeOrder.firstIndex(of: "jawOpen")!

    static func frames(_ duration: Double, moving: [ClosedRange<Double>] = [], untracked: (Int) -> Bool = { _ in false }) -> [FaceFrame] {
        (0 ..< Int(duration * 60)).map { i in
            let t = Double(i) / 60
            if untracked(i) { return .untracked(at: t0 + t) }
            var shapes = [Float](repeating: 0.1, count: Constants.blendShapeCount)
            if moving.contains(where: { $0.contains(t) }) {
                shapes[jaw] = Float(0.3 + 0.3 * sin(2 * .pi * 4 * t))
            }
            return FaceFrame(timestamp: t0 + t, trackingFlags: [.isTracked, .trackingNormal], blendShapes: shapes,
                             headTransform: Array(repeating: 0, count: 16),
                             lipVertices: Array(repeating: .zero, count: Constants.lipVertexCount))
        }
    }

    static func audio(_ duration: Double, voiced: [ClosedRange<Double>] = [], db: Double = -20) -> [Int16] {
        let peak = pow(10, db / 20) * 2.0.squareRoot() * 32_768
        return (0 ..< Int(duration * 16_000)).map { n in
            let t = Double(n) / 16_000
            return voiced.contains(where: { $0.contains(t) }) ? Int16(peak * sin(2 * .pi * 200 * t)) : 0
        }
    }

    static func track(_ scores: [Double]) -> MouthActivity.Track {
        MouthActivity.Track(times: scores.indices.map { Double($0) / 60 }, scores: scores,
                            tracked: Array(repeating: true, count: scores.count))
    }
}

@Suite("Mouth activity and gate")
struct MouthGateTests {
    @Test func stillFaceScoresZeroAndMovingFaceScoresHigh() {
        let track = MouthActivity.track(GateFixture.frames(2, moving: [1 ... 2]))
        #expect(track.scores.count == 120)
        #expect(track.scores[..<60].allSatisfy { $0 == 0 })
        #expect(track.scores[70 ..< 120].allSatisfy { $0 > MouthActivity.defaultThreshold })
        #expect(track.trackedRatio == 1)
    }

    @Test func gateOpensOnlyAfter80msAboveThreshold() {
        let short = [Double](repeating: 0, count: 10) + [Double](repeating: 5, count: 4) + [Double](repeating: 0, count: 30)
        #expect(MouthGate.rawRegions(GateFixture.track(short), threshold: 1).isEmpty)
        let long = [Double](repeating: 0, count: 10) + [Double](repeating: 5, count: 7) + [Double](repeating: 0, count: 30)
        let regions = MouthGate.rawRegions(GateFixture.track(long), threshold: 1)
        #expect(regions.count == 1)
        #expect(abs(regions[0].start - 10.0 / 60) < 1e-9)
        #expect(abs(regions[0].end - 17.0 / 60) < 1e-9)
    }

    @Test func shortDipsDoNotCloseTheGate() {
        // A 200 ms dip below 0.6 θ is shorter than the 300 ms close time.
        let scores = [Double](repeating: 5, count: 30) + [Double](repeating: 0, count: 12) + [Double](repeating: 5, count: 30)
            + [Double](repeating: 0, count: 30)
        #expect(MouthGate.rawRegions(GateFixture.track(scores), threshold: 1).count == 1)
        // A score between 0.6 θ and θ keeps an open gate open.
        let hovering = [Double](repeating: 5, count: 30) + [Double](repeating: 0.8, count: 60)
        let regions = MouthGate.rawRegions(GateFixture.track(hovering), threshold: 1)
        #expect(regions.count == 1 && abs(regions[0].end - 89.0 / 60) < 1e-9)
    }

    @Test func regionsMergeAndPad() {
        let burst = [Double](repeating: 5, count: 12)
        let quiet = [Double](repeating: 0, count: 21) // 350 ms, enough to close, under the 400 ms merge gap
        let scores = quiet + burst + quiet + burst + [Double](repeating: 0, count: 60)
        #expect(MouthGate.rawRegions(GateFixture.track(scores), threshold: 1).count == 2)
        let regions = MouthGate.regions(GateFixture.track(scores), threshold: 1)
        #expect(regions.count == 1)
        #expect(abs(regions[0].start - (21.0 / 60 - 0.15)) < 1e-9)
        #expect(abs(regions[0].end - (66.0 / 60 + 0.25)) < 1e-9)
    }

    @Test func speechWithMovingMouthPassesTrimmed() throws {
        let frames = GateFixture.frames(3, moving: [1 ... 2])
        let audio = GateFixture.audio(3, voiced: [1 ... 2])
        let result = MouthGate.apply(frames: frames, audio: audio, audioT0: GateFixture.t0)
        #expect(!result.bypassed)
        let region = try #require(result.regions.first)
        #expect(result.regions.count == 1)
        #expect((GateFixture.t0 + 0.8 ... GateFixture.t0 + 0.95).contains(region.start))
        #expect((GateFixture.t0 + 2.2 ... GateFixture.t0 + 2.5).contains(region.end))
        guard case let .speech(gated, startSample) = result.decision else {
            Issue.record("expected speech, got \(result.decision)")
            return
        }
        #expect(startSample == Int(((region.start - GateFixture.t0) * 16_000).rounded()))
        #expect(gated == Array(audio[startSample ..< startSample + gated.count]))
        #expect(result.voicedRatio > 0.6)
        #expect(abs(result.gatedOutSeconds - (3 - Double(gated.count) / 16_000)) < 1e-9)
    }

    @Test func speechThatStartsBeforeTheCameraKeepsItsStart() throws {
        // Audio from t0, face frames only from t0 + 0.42 s, with the mouth already moving.
        let frames = GateFixture.frames(3, moving: [0 ... 1.5]).filter { $0.timestamp >= GateFixture.t0 + 0.42 }
        let audio = GateFixture.audio(3, voiced: [0.1 ... 1.5])
        let result = MouthGate.apply(frames: frames, audio: audio, audioT0: GateFixture.t0)
        #expect(result.regions.first?.start == GateFixture.t0)
        guard case let .speech(_, startSample) = result.decision else {
            Issue.record("expected speech, got \(result.decision)")
            return
        }
        #expect(startSample == 0)

        // Movement that starts later than the first frames keeps its normal padded start.
        let late = MouthGate.apply(frames: GateFixture.frames(3, moving: [1 ... 2]).filter { $0.timestamp >= GateFixture.t0 + 0.42 },
                                   audio: GateFixture.audio(3, voiced: [1 ... 2]), audioT0: GateFixture.t0)
        #expect(try #require(late.regions.first).start > GateFixture.t0 + 0.8)
    }

    @Test func someoneElseTalkingWhileMouthIsStillInsertsNothing() {
        let result = MouthGate.apply(frames: GateFixture.frames(3), audio: GateFixture.audio(3, voiced: [0.5 ... 2.5]),
                                     audioT0: GateFixture.t0)
        #expect(result.decision == .noActivity)
        #expect(result.regions.isEmpty)
    }

    @Test func mouthingWithoutSoundIsSilentMouthing() {
        let result = MouthGate.apply(frames: GateFixture.frames(3, moving: [1 ... 2]), audio: GateFixture.audio(3),
                                     audioT0: GateFixture.t0)
        #expect(result.decision == .silentMouthing)
        #expect(result.voicedRatio == 0)
    }

    @Test func longClosedGapsAreZeroedNotCut() throws {
        let frames = GateFixture.frames(4.5, moving: [1 ... 1.5, 3 ... 3.5])
        let audio = GateFixture.audio(4.5, voiced: [1 ... 1.5, 2.2 ... 2.4, 3 ... 3.5])
        let result = MouthGate.apply(frames: frames, audio: audio, audioT0: GateFixture.t0)
        #expect(result.regions.count == 2)
        guard case let .speech(gated, startSample) = result.decision else {
            Issue.record("expected speech, got \(result.decision)")
            return
        }
        func sample(_ t: Double) -> Int { Int(t * 16_000) - startSample }
        #expect(gated[sample(1.25)] != 0 || gated[sample(1.25) + 5] != 0)
        // The 2.2 … 2.4 s sound came while the mouth was still, so it's zeroed in place.
        #expect(gated[sample(2.2) ..< sample(2.4)].allSatisfy { $0 == 0 })
        #expect(gated[sample(3.25) ..< sample(3.25) + 100].contains { $0 != 0 })
        let span = (result.regions[1].end - result.regions[0].start) * 16_000
        #expect(abs(Double(gated.count) - span) <= 2)
    }

    @Test func poorTrackingBypassesTheGate() {
        let frames = GateFixture.frames(3, untracked: { $0 % 3 == 0 })
        let audio = GateFixture.audio(3, voiced: [1 ... 2])
        let result = MouthGate.apply(frames: frames, audio: audio, audioT0: GateFixture.t0)
        #expect(result.bypassed)
        #expect(result.decision == .speech(audio: audio, startSample: 0))

        let quiet = MouthGate.apply(frames: frames, audio: GateFixture.audio(3), audioT0: GateFixture.t0)
        #expect(quiet.bypassed && quiet.decision == .noActivity)
    }

    @Test func thresholdComesFromNeutralTakes() throws {
        var generator = SplitMix(seed: 7)
        let jaw = GateFixture.jaw
        let neutral = (0 ..< 600).map { i -> FaceFrame in
            var shapes = [Float](repeating: 0.1, count: Constants.blendShapeCount)
            shapes[jaw] += Float.random(in: -0.004 ... 0.004, using: &generator)
            return FaceFrame(timestamp: Double(i) / 60, trackingFlags: [.isTracked], blendShapes: shapes,
                             headTransform: Array(repeating: 0, count: 16),
                             lipVertices: Array(repeating: .zero, count: Constants.lipVertexCount))
        }
        let theta = try #require(MouthActivity.threshold(neutral: [neutral]))
        let scores = MouthActivity.track(neutral).scores.dropFirst()
        let mean = scores.reduce(0, +) / Double(scores.count)
        #expect(theta > mean)
        #expect(scores.count { $0 > theta } < scores.count / 100)
        #expect(MouthActivity.threshold(neutral: []) == nil)
    }
}

/// Deterministic generator for the tests.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Dictation text and audio")
struct DictationTests {
    @Test func prepareRemovesDcAndNormalisesPeak() {
        let samples: [Int16] = [1_100, 900, 1_100, 900, 1_000]
        let prepared = DictationAudio.prepare(samples)
        #expect(abs(prepared.reduce(0, +)) < 1e-5)
        #expect(abs(prepared.map(abs).max()! - Float(pow(10, -3.0 / 20))) < 1e-5)
        #expect(DictationAudio.prepare([0, 0, 0]) == [0, 0, 0])
        #expect(DictationAudio.prepare([]).isEmpty)
    }

    @Test func quietSpeechIsTaggedWhisper() {
        #expect(DictationAudio.speechStyle(gatedAudio: GateFixture.audio(1, voiced: [0 ... 1], db: -36)) == .whisper)
        #expect(DictationAudio.speechStyle(gatedAudio: GateFixture.audio(1, voiced: [0 ... 1], db: -18)) == .aloud)
    }

    @Test func hallucinationsDropOnlyOnShortOrQuietClips() {
        #expect(DictationText.isHallucination(" Thank you. ", clipDuration: 1.0, speechDuration: 0.8))
        #expect(DictationText.isHallucination("you", clipDuration: 4, speechDuration: 0.2))
        #expect(!DictationText.isHallucination("Thank you.", clipDuration: 3, speechDuration: 1.5))
        #expect(!DictationText.isHallucination("Thank you so much.", clipDuration: 1, speechDuration: 0.2))
    }

    @Test func cleanupCollapsesWhitespaceAndAppliesReplacements() {
        let replacements = DictationText.replacements(from: """
        new line => \\n
        tacit type => Tacit Type
        no arrow here
        => nothing
        """)
        #expect(replacements == [.init(from: "new line", to: "\n"), .init(from: "tacit type", to: "Tacit Type")])
        #expect(DictationText.clean("  hello   there \n friend ") == "hello there friend")
        #expect(DictationText.clean(" Dear Sam, new line. Running late. New line Thanks", replacements: replacements)
            == "Dear Sam,\nRunning late.\nThanks")
        #expect(DictationText.clean("I use tacit type daily", replacements: replacements) == "I use Tacit Type daily")
        #expect(DictationText.clean("the newline character", replacements: replacements) == "the newline character")
        #expect(DictationText.clean("cost $5", replacements: [.init(from: "cost", to: "$1 price")]) == "$1 price $5")
    }

    @Test func vocabularySplitsOnLinesAndCommas() {
        #expect(DictationText.vocabulary(from: "Faisal, WhisperKit\n\n  TrueDepth ,") == ["Faisal", "WhisperKit", "TrueDepth"])
    }

    @Test func wordErrorRate() {
        #expect(WordErrorRate.normalise("The birch canoe, slid! Don't") == ["the", "birch", "canoe", "slid", "don't"])
        #expect(WordErrorRate.wer(reference: "The birch canoe slid", hypothesis: "the birch canoe slid.") == 0)
        #expect(WordErrorRate.wer(reference: "a b c d", hypothesis: "a x c") == 0.5)
        #expect(WordErrorRate.wer(reference: "a b", hypothesis: "a b c d") == 1)
        #expect(WordErrorRate.wer(reference: "", hypothesis: "a") == nil)
        #expect(WordErrorRate.corpus([("a b c d", "a b c d"), ("e f", "e")]) == 1.0 / 6)
    }
}
