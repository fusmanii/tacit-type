import Foundation
import simd
import Testing
@testable import TacitKit

/// Landmarks of an upright face in image pixels: eyes level at y = 300, mouth 64 px wide centred at (500, 420).
/// `angle` rotates the whole face about the mouth centre, in radians.
func faceLandmarks(angle: Float = 0, centre: SIMD2<Float> = SIMD2(500, 420)) -> [SIMD2<Float>] {
    var points = [SIMD2<Float>](repeating: .zero, count: Constants.cropLandmarkCount)
    func set(_ slot: CropLandmark, _ x: Float, _ y: Float) { points[slot.rawValue] = SIMD2(x, y) }
    set(.eyeOuterLowX, -70, -120); set(.eyeInnerLowX, -25, -120)
    set(.eyeInnerHighX, 25, -120); set(.eyeOuterHighX, 70, -120)
    set(.noseBridge, 0, -95); set(.noseTip, 0, -50); set(.noseBase, 0, -35)
    set(.mouthCornerLowX, -32, 0); set(.mouthCornerHighX, 32, 0)
    set(.upperLipCentre, 0, -8); set(.lowerLipCentre, 0, 8)
    set(.chin, 0, 90)
    let (c, s) = (cos(angle), sin(angle))
    return points.map { p in centre + SIMD2(c * p.x - s * p.y, s * p.x + c * p.y) }
}

/// A smooth gradient frame for video and JPEG tests: 30 + x/2 + y/4 + `step`, where x and y are pixel coordinates.
func gradientFrame(step: Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: 192 * 192)
    for y in 0 ..< 192 {
        for x in 0 ..< 192 {
            let value: Int = 30 + x / 2 + y / 4 + step
            pixels[y * 192 + x] = UInt8(clamping: value)
        }
    }
    return pixels
}

/// A smooth test image so resampling error stays small: value = 20 + 0.1 x + 0.15 y, clamped.
func gradientImage(width: Int, height: Int) -> [UInt8] {
    (0 ..< width * height).map { i in
        let (x, y) = (Double(i % width), Double(i / width))
        return UInt8(clamping: Int((20 + 0.1 * x + 0.15 * y).rounded()))
    }
}

@Suite("Mouth wire format")
struct MouthWireTests {
    @Test func frameLayoutIsAsSpecced() throws {
        let frame = MouthFrame(timestamp: 2.5, landmarks: [SIMD2(1, -1)], jpeg: Data([0xFF, 0xD8, 0x00]))
        let payload = try Message.mouthBatch(MouthBatch(frames: [frame])).encodedPayload()
        var expected: [UInt8] = [1, 0]
        expected += withUnsafeBytes(of: (2.5).bitPattern.littleEndian, Array.init)
        expected += [1]
        expected += withUnsafeBytes(of: Float(1).bitPattern.littleEndian, Array.init)
        expected += withUnsafeBytes(of: Float(-1).bitPattern.littleEndian, Array.init)
        expected += [3, 0, 0, 0, 0xFF, 0xD8, 0x00]
        #expect(Array(payload) == expected)
    }

    @Test func rejectsTrailingBytes() throws {
        let payload = try Message.mouthBatch(MouthBatch(frames: [])).encodedPayload() + Data([0])
        #expect(throws: ProtocolDecodeError.lengthMismatch) { try Message(type: .mouthBatch, payload: payload) }
    }

    @Test func batcherFlushesEvery200Ms() {
        var batcher = MouthBatcher()
        var batches: [MouthBatch] = []
        for i in 0 ..< 25 {
            if let batch = batcher.append(MouthFrame(timestamp: Double(i) * 0.04, landmarks: [], jpeg: Data())) {
                batches.append(batch)
            }
        }
        #expect(batches.map(\.frames.count) == [5, 5, 5, 5])
        #expect(batcher.flush()?.frames.count == 5)
        #expect(batcher.flush() == nil)
    }

    @Test func samplerKeepsTheFrameNearestEachTick() {
        var sampler = MouthFrameSampler()
        let times = (0 ..< 600).map { 100 + Double($0) / 60 }
        let kept = times.filter { sampler.shouldKeep($0) }
        #expect(kept.count == 250)
        for (index, time) in kept.enumerated() {
            #expect(abs(time - (100 + Double(index) * 0.04)) <= 1.0 / 120 + 1e-9)
        }
    }

    @Test func samplerSkipsTicksAcrossAGap() {
        var sampler = MouthFrameSampler()
        var times = (0 ..< 60).map { Double($0) / 60 }
        times += (90 ..< 150).map { Double($0) / 60 }
        let kept = times.filter { sampler.shouldKeep($0) }
        #expect(kept.count == 51)
        let gaps = zip(kept.dropFirst(), kept).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 < 0.06 || abs($0 - 0.533) < 0.02 })
    }
}

@Suite("Mouth crop")
struct MouthCropTests {
    @Test func upright() throws {
        let crop = try #require(MouthCrop(landmarks: faceLandmarks()))
        #expect(crop.side == 192)
        #expect(simd_distance(crop.cropPoint(SIMD2(500, 420)), SIMD2(96, 96)) < 1e-3)
        #expect(simd_distance(crop.cropPoint(SIMD2(468, 420)), SIMD2(64, 96)) < 1e-3)
        let eye = crop.cropPoint(faceLandmarks()[CropLandmark.eyeInnerLowX.rawValue])
        #expect(eye.y < 0)
    }

    @Test(arguments: [0.3, -0.5, Float.pi / 2, -Float.pi / 2, Float.pi])
    func staysUprightWhateverTheImageRotation(angle: Float) throws {
        let landmarks = faceLandmarks(angle: angle)
        let crop = try #require(MouthCrop(landmarks: landmarks))
        let mouth = landmarks.map(crop.cropPoint)
        let low = mouth[CropLandmark.mouthCornerLowX.rawValue]
        let high = mouth[CropLandmark.mouthCornerHighX.rawValue]
        #expect(abs(low.y - 96) < 1e-2 && abs(high.y - 96) < 1e-2)
        #expect(abs(abs(high.x - low.x) - 64) < 1e-2)
        #expect(mouth[CropLandmark.noseTip.rawValue].y < 96)
        #expect(mouth[CropLandmark.chin.rawValue].y > 96)
        for point in [SIMD2<Float>(10, 20), SIMD2(150, 90)] {
            #expect(simd_distance(crop.cropPoint(crop.imagePoint(point)), point) < 1e-3)
        }
    }

    @Test func rejectsDegenerateLandmarks() {
        #expect(MouthCrop(landmarks: Array(repeating: .zero, count: Constants.cropLandmarkCount)) == nil)
        #expect(MouthCrop(landmarks: []) == nil)
    }

    @Test(arguments: [Float(0), 0.4, Float.pi / 2])
    func extractSamplesTheRightPlace(angle: Float) throws {
        let (width, height) = (1000, 800)
        let image = gradientImage(width: width, height: height)
        let crop = try #require(MouthCrop(landmarks: faceLandmarks(angle: angle)))
        let pixels = image.withUnsafeBytes { crop.extract(from: $0.baseAddress!, width: width, height: height, bytesPerRow: width) }
        #expect(pixels.count == 192 * 192)
        var worst = 0.0
        for (x, y) in [(0, 0), (96, 96), (191, 0), (20, 170), (191, 191)] {
            let p = crop.imagePoint(SIMD2(Float(x) + 0.5, Float(y) + 0.5))
            let expected = 20 + 0.1 * Double(p.x) + 0.15 * Double(p.y)
            worst = max(worst, abs(Double(pixels[y * 192 + x]) - expected))
        }
        #expect(worst < 1.5)
    }

    @Test func jpegRoundTrips() throws {
        let pixels = gradientFrame(step: 0)
        let jpeg = try MouthJPEG.encode(pixels)
        #expect(jpeg.count < 20_000)
        let decoded = try MouthJPEG.decode(jpeg)
        #expect(zip(decoded, pixels).map { abs(Int($0) - Int($1)) }.max()! <= 3)
        #expect(throws: MouthJPEG.CodingError.wrongSize(width: 192, height: 192)) { try MouthJPEG.decode(jpeg, size: 96) }
    }

    @Test func pixelStatistics() {
        #expect(MouthPixels.meanLuma([0, 100, 200]) == 100)
        var pixels = [UInt8](repeating: 200, count: 192 * 192)
        let closed = MouthPixels.openness(pixels)
        for y in 85 ..< 107 { for x in 70 ..< 122 { pixels[y * 192 + x] = 20 } }
        #expect(MouthPixels.openness(pixels) > closed + 100)
    }
}

@Suite("Crop landmark selector")
struct CropLandmarkSelectorTests {
    /// A flat 5 mm grid face with holes for two eyes and a mouth, and a nose bump.
    static let face: (vertices: [SIMD3<Float>], triangles: [Int]) = {
        let step: Float = 0.005
        let columns = 33, rows = 45 // x −0.08 … 0.08, y −0.12 … 0.10
        func position(_ c: Int, _ r: Int) -> SIMD2<Float> { SIMD2(Float(c - 16) * step, Float(r) * step - 0.12) }
        var vertices: [SIMD3<Float>] = []
        for r in 0 ..< rows {
            for c in 0 ..< columns {
                let p = position(c, r)
                // Nose: a ridge on the midline from y = 0.045 down to the tip at y = −0.02, with a dip just below it.
                var z = 0.03 * exp(-pow(p.x / 0.012, 2)) * max(0, min(1, (0.045 - p.y) / 0.065))
                if p.y < -0.02 { z = 0.03 * exp(-pow(p.x / 0.012, 2)) * exp(-pow((p.y + 0.02) / 0.006, 2)) }
                if p.y < -0.025, p.y > -0.045 { z -= 0.004 * exp(-pow(p.x / 0.01, 2)) }
                vertices.append(SIMD3(p.x, p.y, z))
            }
        }
        func inHole(_ p: SIMD2<Float>) -> Bool {
            let eye = { (cx: Float) in pow((p.x - cx) / 0.016, 2) + pow((p.y - 0.045) / 0.006, 2) < 1 }
            return eye(-0.035) || eye(0.035) || pow(p.x / 0.026, 2) + pow((p.y + 0.06) / 0.006, 2) < 1
        }
        var triangles: [Int] = []
        for r in 0 ..< rows - 1 {
            for c in 0 ..< columns - 1 {
                let centre = position(c, r) + SIMD2(step / 2, step / 2)
                guard !inHole(centre) else { continue }
                let (a, b, d, e) = (r * columns + c, r * columns + c + 1, (r + 1) * columns + c, (r + 1) * columns + c + 1)
                triangles += [a, b, e, a, e, d]
            }
        }
        return (vertices, triangles)
    }()

    @Test func picksEachLandmark() throws {
        let (vertices, triangles) = Self.face
        let slots = try CropLandmarkSelector.select(vertices: vertices, triangleIndices: triangles)
        #expect(slots.count == 12)
        func at(_ slot: CropLandmark) -> SIMD3<Float> { vertices[slots[slot.rawValue]] }

        #expect(at(.eyeOuterLowX).x < at(.eyeInnerLowX).x)
        #expect(at(.eyeInnerLowX).x < 0 && at(.eyeInnerHighX).x > 0)
        #expect(at(.eyeInnerHighX).x < at(.eyeOuterHighX).x)
        #expect([CropLandmark.eyeOuterLowX, .eyeInnerLowX, .eyeInnerHighX, .eyeOuterHighX].allSatisfy { abs(at($0).y - 0.045) < 0.006 })
        #expect(at(.mouthCornerLowX).x < -0.02 && at(.mouthCornerHighX).x > 0.02)
        #expect(at(.upperLipCentre).y > at(.lowerLipCentre).y)
        #expect(abs(at(.upperLipCentre).x) < 0.003 && abs(at(.lowerLipCentre).x) < 0.003)
        #expect(abs(at(.noseTip).y + 0.02) < 0.006)
        #expect(at(.noseBridge).y > at(.noseTip).y && at(.noseBridge).y < 0.045)
        #expect(at(.noseBase).y < at(.noseTip).y && at(.noseBase).y > at(.upperLipCentre).y)
        #expect(at(.noseBase).z < 0)
        #expect(at(.chin).y < -0.11)
    }

    @Test func usesTheGivenMouthCorners() throws {
        let (vertices, triangles) = Self.face
        let slots = try CropLandmarkSelector.select(vertices: vertices, triangleIndices: triangles, mouthCorners: (low: 7, high: 9))
        #expect(slots[CropLandmark.mouthCornerLowX.rawValue] == 7 && slots[CropLandmark.mouthCornerHighX.rawValue] == 9)
    }

    @Test func failsWithoutHoles() {
        let triangles = [0, 1, 2]
        #expect(throws: CropLandmarkSelector.SelectionError.holesNotFound(found: 0)) {
            try CropLandmarkSelector.select(vertices: [.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0)], triangleIndices: triangles)
        }
    }
}

@Suite("Mouth files")
struct MouthFileTests {
    static func frames(_ count: Int) throws -> [MouthFrame] {
        try (0 ..< count).map { k in
            let pixels = gradientFrame(step: 10 * k)
            let landmarks = (0 ..< Constants.cropLandmarkCount).map { SIMD2(Float($0 * 10 + k), Float($0 * 5) - 20) }
            return MouthFrame(timestamp: 81_234.52 + Double(k) * 0.04, landmarks: landmarks, jpeg: try MouthJPEG.encode(pixels))
        }
    }

    @Test func headerAndRoundTrip() throws {
        let frames = try Self.frames(3)
        let data = try MouthFile.encode(frames)
        #expect(data.count == 12 + 3 * (8 + 12 * 8))
        #expect(Array(data.prefix(12)) == [0x53, 0x4D, 0x54, 0x48, 1, 0, 12, 0, 3, 0, 0, 0])
        let records = try MouthFile.decode(data)
        #expect(records == frames.map { MouthFile.Record(timestamp: $0.timestamp, landmarks: $0.landmarks) })

        var other = data
        other[4] = 2
        #expect(throws: SessionFileError.mouthVersionMismatch(found: 2)) { try MouthFile.decode(other) }
        #expect(throws: SessionFileError.lengthMismatch) { try MouthFile.decode(data.dropLast()) }
    }

    @Test func videoRangeMapsBothWays() {
        #expect(MouthVideo.toVideoRange(0) == 16 && MouthVideo.toVideoRange(255) == 235)
        #expect((0 ... 255).allSatisfy { abs(Int(MouthVideo.toFullRange(MouthVideo.toVideoRange(UInt8($0)))) - $0) <= 1 })
    }

    @Test func videoRoundTrips() async throws {
        let pixels = (0 ..< 30).map { gradientFrame(step: 3 * $0) }
        let url = FileManager.default.temporaryDirectory.appending(path: "tacit-mouth-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await MouthVideo.write(pixels, to: url)
        let decoded = try await MouthVideo.read(url)
        #expect(decoded.count == 30)
        for (got, want) in zip(decoded, pixels) {
            let error = zip(got, want).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            #expect(Double(error) / Double(want.count) < 2)
        }
    }
}

@Suite("Mouth capture checks")
struct MouthCaptureTests {
    @Test func recordingCountsMouthFrames() throws {
        var recording = CaptureRecording(sessionId: UUID())
        recording.append(FaceBatch(frames: (0 ..< 61).map { FaceFrame.untracked(at: 10 + Double($0) / 60) }))
        let frames = try MouthFileTests.frames(3)
        recording.append(MouthBatch(frames: frames))
        let metrics = recording.metrics
        #expect(metrics.mouthFrameCount == 3)
        #expect(metrics.expectedMouthFrames == 26)
        #expect(abs(metrics.mouthFps - 25) < 1e-6)
        #expect(abs((metrics.meanLuma ?? 0) - 111) < 3)
        #expect(recording.mouthPixels().count == 3)

        var manifest = SessionFixture.aloud.manifest
        manifest.fill(from: metrics)
        #expect(manifest.mouthFrameCount == 3 && manifest.mouthFps == metrics.mouthFps)
    }

    @Test func flagsDarkAndMissingVideo() {
        var metrics = CaptureMetrics()
        metrics.trackedRatio = 1
        metrics.measuredFps = 60
        metrics.mouthFrameCount = 98
        metrics.expectedMouthFrames = 100
        metrics.meanLuma = 120
        let quiet = [Int16](repeating: 0, count: 32_000)
        func flags(_ m: CaptureMetrics, mouth: Bool = true) -> [TakeQuality.Flag] {
            TakeQuality.flags(metrics: m, audio: quiet, style: .silent, duration: 2, expectedDuration: 3, expectsMouth: mouth)
        }
        #expect(flags(metrics).isEmpty)
        var dark = metrics
        dark.meanLuma = 55
        #expect(flags(dark) == [.lowLight])
        #expect(flags(dark, mouth: false).isEmpty)
        var dropped = metrics
        dropped.mouthFrameCount = 97
        #expect(flags(dropped) == [.mouthDropped])
        var none = metrics
        none.mouthFrameCount = 0
        none.expectedMouthFrames = 0
        none.meanLuma = nil
        #expect(flags(none) == [.mouthDropped])
    }

    /// "pa" bursts in the audio, and mouth crops whose middle darkens with each burst, shifted by `videoDelay`.
    @Test(arguments: [0, 0.012, -0.017, 0.045]) func videoSyncRecoversKnownLag(videoDelay: Double) throws {
        let start = 7_000.0
        let length = 3.5
        let centres = (0 ..< 5).map { 0.6 + 0.55 * Double($0) }
        func bump(_ t: Double) -> Double { centres.reduce(0) { $0 + exp(-pow((t - $1) / 0.07, 2)) } }
        let audio = (0 ..< Int(length * 16_000)).map { n -> Int16 in
            Int16(12_000 * bump(Double(n) / 16_000) * sin(2 * .pi * 180 * Double(n) / 16_000))
        }
        // Each video frame shows the mouth as it was `videoDelay` before its timestamp says.
        let times = (0 ..< Int(length * 25)).map { start + Double($0) / 25 + 0.003 }
        let pixels = times.map { time -> [UInt8] in
            let dark = UInt8(200 - 150 * min(1, bump(time - start - videoDelay)))
            var frame = [UInt8](repeating: 200, count: 192 * 192)
            for y in 80 ..< 112 { for x in 64 ..< 128 { frame[y * 192 + x] = dark } }
            return frame
        }
        let result = try #require(SyncCheck.measureVideo(times: times, pixels: pixels, audio: audio, audioT0: start))
        // Positive lag means the sound comes later than the movement, so a late video gives a negative lag.
        #expect(abs(result.lagMs + videoDelay * 1000) < 3)
        #expect(result.passed == (abs(videoDelay) < 0.02))
    }
}
