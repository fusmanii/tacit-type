import Foundation
import Testing
@testable import TacitKit

private func frame(at timestamp: Double, tracked: Bool = true) -> FaceFrame {
    var frame = FaceFrame.untracked(at: timestamp)
    if tracked { frame.trackingFlags = [.isTracked, .trackingNormal] }
    return frame
}

private func frames(count: Int, fps: Double = 60, start: Double = 1_000, skipping skipped: Set<Int> = []) -> [FaceFrame] {
    (0 ..< count).filter { !skipped.contains($0) }.map { frame(at: start + Double($0) / fps) }
}

@Suite("Face batcher")
struct FaceBatcherTests {
    @Test func sixtyFpsMakesSixFrameBatches() {
        var batcher = FaceBatcher()
        var batches: [FaceBatch] = []
        for frame in frames(count: 61) {
            if let batch = batcher.append(frame) { batches.append(batch) }
        }
        #expect(batches.count == 10)
        #expect(batches.allSatisfy { $0.frames.count == 6 })
        #expect(batcher.flush()?.frames.count == 1)
        #expect(batcher.flush() == nil)
        #expect(batcher.isEmpty)
    }

    @Test func flushOnStopSendsPartialBatch() {
        var batcher = FaceBatcher()
        for frame in frames(count: 3) { #expect(batcher.append(frame) == nil) }
        #expect(batcher.flush()?.frames.map(\.timestamp) == frames(count: 3).map(\.timestamp))
    }
}

@Suite("Capture recording")
struct CaptureRecordingTests {
    @Test func cleanSixtySecondsAtSixtyFps() {
        var recording = CaptureRecording(sessionId: UUID())
        let all = frames(count: 3_601)
        for start in stride(from: 0, to: all.count, by: 6) {
            recording.append(FaceBatch(frames: Array(all[start ..< min(start + 6, all.count)])))
        }
        let metrics = recording.metrics
        #expect(metrics.frameCount == 3_601)
        #expect(abs(metrics.measuredFps - 60) < 1e-6)
        #expect(metrics.droppedFrames == 0)
        #expect(metrics.trackedRatio == 1)
        #expect(abs(metrics.faceDuration - 60) < 1e-6)
        #expect(metrics.firstFaceTs == 1_000)
    }

    @Test func countsDroppedFramesFromTimestampGaps() {
        var recording = CaptureRecording(sessionId: UUID())
        // One single drop and a run of three.
        recording.append(FaceBatch(frames: frames(count: 120, skipping: [10, 50, 51, 52])))
        let metrics = recording.metrics
        #expect(metrics.droppedFrames == 4)
        #expect(abs(metrics.droppedRatio - 4.0 / 120) < 1e-9)
    }

    @Test func toleratesTimestampJitter() {
        var recording = CaptureRecording(sessionId: UUID())
        let jittered = (0 ..< 120).map { i in frame(at: 1_000 + Double(i) / 60 + (i.isMultiple(of: 2) ? 0.002 : -0.002)) }
        recording.append(FaceBatch(frames: jittered))
        #expect(recording.metrics.droppedFrames == 0)
    }

    @Test func trackedRatioAndFirstTrackedFrame() {
        var recording = CaptureRecording(sessionId: UUID())
        recording.append(FaceBatch(frames: [frame(at: 1, tracked: false), frame(at: 2), frame(at: 3), frame(at: 4)]))
        #expect(recording.metrics.trackedRatio == 0.75)
        #expect(recording.metrics.firstFaceTs == 1)
        #expect(recording.metrics.firstTrackedFaceTs == 2)
    }

    @Test func contiguousAudioHasNoGaps() {
        var recording = CaptureRecording(sessionId: UUID())
        for i in 0 ..< 100 {
            recording.append(AudioChunk(ptsOfFirstSample: 500 + Double(i) * 0.02, samples: Array(repeating: 1, count: 320)))
        }
        #expect(recording.audioT0 == 500)
        #expect(recording.audio.count == 32_000)
        #expect(recording.audioGapsFilled == 0)
        #expect(recording.metrics.audioDuration == 2)
    }

    @Test func fillsGapsWithZerosSoTimeStaysLinear() {
        var recording = CaptureRecording(sessionId: UUID())
        recording.append(AudioChunk(ptsOfFirstSample: 10, samples: Array(repeating: 7, count: 160)))
        // 10 ms missing.
        recording.append(AudioChunk(ptsOfFirstSample: 10.02, samples: Array(repeating: 9, count: 160)))
        #expect(recording.audioGapsFilled == 1)
        #expect(recording.audio.count == 480)
        #expect(recording.audio[160 ..< 320].allSatisfy { $0 == 0 })
        #expect(recording.audio[320] == 9)
    }

    @Test func ignoresSubMillisecondJitterAndDropsOverlap() {
        var recording = CaptureRecording(sessionId: UUID())
        recording.append(AudioChunk(ptsOfFirstSample: 10, samples: Array(repeating: 1, count: 160)))
        recording.append(AudioChunk(ptsOfFirstSample: 10.0105, samples: Array(repeating: 2, count: 160)))
        #expect(recording.audio.count == 320)
        // Starts 5 ms (80 samples) before the end of what we have.
        recording.append(AudioChunk(ptsOfFirstSample: 10.015, samples: Array(repeating: 3, count: 160)))
        #expect(recording.audio.count == 400)
        #expect(recording.audioGapsFilled == 0)
    }
}

@Suite("Latency stats")
struct LatencyStatsTests {
    @Test func nearestRankPercentiles() {
        var stats = LatencyStats()
        for value in (1 ... 20).shuffled() { stats.add(Double(value)) }
        #expect(stats.p50 == 10)
        #expect(stats.p95 == 19)
        #expect(stats.percentile(100) == 20)
        #expect(LatencyStats().p95 == nil)
    }

    @Test func keepsOnlyTheNewestSamples() {
        var stats = LatencyStats(capacity: 3)
        for value in 1 ... 5 { stats.add(Double(value)) }
        #expect(stats.samples == [3, 4, 5])
    }
}

/// A flat grid face, 2 mm spacing, with a mouth hole and an eye hole cut out of it.
private struct GridFace {
    static let spacing: Float = 0.002
    static let columns = 41 // x from -0.04 to 0.04
    static let rows = 51 // y from -0.08 to 0.02

    var vertices: [SIMD3<Float>] = []
    var triangles: [Int] = []

    init(holes: [(x: ClosedRange<Float>, y: ClosedRange<Float>)]) {
        for row in 0 ..< Self.rows {
            for column in 0 ..< Self.columns {
                vertices.append(SIMD3(-0.04 + Float(column) * Self.spacing, -0.08 + Float(row) * Self.spacing, 0.05))
            }
        }
        for row in 0 ..< Self.rows - 1 {
            for column in 0 ..< Self.columns - 1 {
                let v00 = row * Self.columns + column
                let (v01, v10, v11) = (v00 + 1, v00 + Self.columns, v00 + Self.columns + 1)
                let centre = (vertices[v00] + vertices[v11]) / 2
                if holes.contains(where: { $0.x.contains(centre.x) && $0.y.contains(centre.y) }) { continue }
                triangles += [v00, v10, v11, v00, v11, v01]
            }
        }
    }

    static let mouth = (x: Float(-0.02) ... 0.02, y: Float(-0.054) ... -0.046)
    static let eye = (x: Float(-0.03) ... -0.01, y: Float(-0.002) ... 0.006)
}

@Suite("Lip vertex selector")
struct LipVertexSelectorTests {
    fileprivate let face = GridFace(holes: [GridFace.mouth, GridFace.eye])

    @Test func findsOuterEdgeMouthAndEyeLoops() {
        #expect(LipVertexSelector.boundaryLoops(triangleIndices: face.triangles).count == 3)
    }

    @Test func picksTheLowerInnerLoopAsTheMouth() throws {
        let contour = try LipVertexSelector.mouthContour(vertices: face.vertices, triangleIndices: face.triangles)
        let ys = contour.map { face.vertices[$0].y }
        #expect(ys.allSatisfy { $0 > -0.0545 && $0 < -0.0455 })
        // A 20 × 4 cell hole has a 48-vertex rim.
        #expect(contour.count == 48)
    }

    @Test func selectsSixtyFourVerticesStartingAtTheCorners() throws {
        let selection = try LipVertexSelector.select(vertices: face.vertices, triangleIndices: face.triangles)
        let options = LipVertexSelector.Options()
        #expect(selection.indices.count == Constants.lipVertexCount)
        #expect(Set(selection.indices).count == Constants.lipVertexCount)

        let contourX = selection.contour.map { face.vertices[$0].x }
        #expect(face.vertices[selection.indices[0]].x == contourX.min())
        #expect(face.vertices[selection.indices[1]].x == contourX.max())

        let rim = selection.contour.map { face.vertices[$0] }
        for index in selection.indices {
            #expect(selection.candidates.contains(index))
            #expect(LipVertexSelector.distance(from: face.vertices[index], toLoop: rim) <= options.radius + 1e-6)
        }
    }

    @Test func isDeterministic() throws {
        let a = try LipVertexSelector.select(vertices: face.vertices, triangleIndices: face.triangles)
        let b = try LipVertexSelector.select(vertices: face.vertices, triangleIndices: face.triangles)
        #expect(a == b)
    }

    @Test func spreadsSamplesAcrossBothLips() throws {
        let selection = try LipVertexSelector.select(vertices: face.vertices, triangleIndices: face.triangles)
        let mouthCentreY: Float = -0.05
        let above = selection.indices.filter { face.vertices[$0].y > mouthCentreY + 0.001 }.count
        let below = selection.indices.filter { face.vertices[$0].y < mouthCentreY - 0.001 }.count
        #expect(above >= 20 && below >= 20)
    }

    @Test func failsWithoutAMouthOpening() {
        let closed = GridFace(holes: [])
        #expect(throws: LipVertexSelector.SelectionError.noMouthOpening) {
            try LipVertexSelector.select(vertices: closed.vertices, triangleIndices: closed.triangles)
        }
    }

    @Test func failsWhenTheRadiusLeavesTooFewCandidates() {
        let options = LipVertexSelector.Options(radius: 0.0001)
        #expect(throws: LipVertexSelector.SelectionError.notEnoughCandidates(found: 48, needed: 64)) {
            try LipVertexSelector.select(vertices: face.vertices, triangleIndices: face.triangles, options: options)
        }
    }
}
