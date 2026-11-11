import Foundation
import Testing
@testable import TacitKit

private func sampleFrame(_ i: Int) -> FaceFrame {
    let base = Float(i)
    return FaceFrame(
        timestamp: 81_234.5 + Double(i) / 60,
        trackingFlags: [.isTracked, .trackingNormal],
        blendShapes: (0 ..< Constants.blendShapeCount).map { base + Float($0) / 100 },
        headTransform: (0 ..< 16).map { Float($0) * 0.25 - base },
        lipVertices: (0 ..< Constants.lipVertexCount).map { SIMD3(Float($0), -Float($0), base) * 0.001 }
    )
}

private let sessionId = UUID(uuidString: "0B8D6C4E-7E35-4B7D-9B1F-3C2E3F6A9D10")!

private let everyMessage: [Message] = [
    .hello(Hello(deviceName: "Faisal's iPhone", deviceModel: "iPhone16,1", appVersion: "0.1.0",
                 capabilities: ["face", "audio"])),
    .start(StartCapture(sessionId: sessionId, mode: .record, promptText: "The birch canoe slid on the smooth planks.")),
    .start(StartCapture(sessionId: sessionId, mode: .command, streams: [.face, .audio])),
    .stop(StopCapture(sessionId: sessionId)),
    .status(DeviceStatus(state: .capturing, trackingState: .normal, faceDetected: true,
                         thermalState: .fair, batteryLevel: 0.82, isCharging: true)),
    .clockPing(ClockSync(t0: 1_000.125)),
    .clockPong(ClockSync(t0: 1_000.125, t1: 1_000.130, t2: 1_000.131)),
    .faceBatch(FaceBatch(frames: (0 ..< 6).map(sampleFrame))),
    .faceBatch(FaceBatch(frames: [])),
    .faceBatch(FaceBatch(frames: [.untracked(at: 42)])),
    .audioChunk(AudioChunk(ptsOfFirstSample: 81_234.498, samples: (0 ..< 1_600).map { Int16(truncatingIfNeeded: $0 * 37) })),
    .audioChunk(AudioChunk(ptsOfFirstSample: 0, samples: [.min, -1, 0, 1, .max])),
    .error(ProtocolErrorMessage(code: .versionMismatch, message: "expected 1, got 2")),
]

@Suite("Message codecs")
struct MessageCodecTests {
    @Test("every message type round-trips through a full frame", arguments: everyMessage)
    func roundTrip(_ message: Message) throws {
        let frame = try message.encodedFrame()
        #expect(frame[0] == message.type.rawValue)
        #expect(frame[1] == Constants.protocolVersion)
        #expect(try Message(frame: frame) == message)
    }

    @Test func coversEveryMessageType() {
        #expect(Set(everyMessage.map(\.type)) == Set(MessageType.allCases))
    }

    @Test func faceFrameIs1052Bytes() {
        #expect(FaceFrame.byteSize == 1_052)
    }

    @Test func sixFrameBatchHasExpectedSize() throws {
        let payload = try Message.faceBatch(FaceBatch(frames: (0 ..< 6).map(sampleFrame))).encodedPayload()
        #expect(payload.count == 2 + 6 * 1_052)
        #expect(payload[0] == 6 && payload[1] == 0)
    }

    @Test func headerLayoutIsLittleEndian() throws {
        let header = MessageHeader(rawType: 0x11, length: 0x0003_0201)
        #expect(Array(header.encoded()) == [0x11, Constants.protocolVersion, 0, 0, 0x01, 0x02, 0x03, 0x00])
        #expect(try MessageHeader(decoding: header.encoded()) == header)
    }

    @Test func audioPayloadLayout() throws {
        let payload = try Message.audioChunk(AudioChunk(ptsOfFirstSample: 1.5, samples: [1, -2])).encodedPayload()
        #expect(Array(payload) == Array(withUnsafeBytes(of: (1.5).bitPattern.littleEndian, Array.init)) + [0x01, 0x00, 0xFE, 0xFF])
    }
}

@Suite("Decode errors")
struct DecodeErrorTests {
    @Test func rejectsVersionMismatch() throws {
        var frame = try Message.stop(StopCapture(sessionId: sessionId)).encodedFrame()
        frame[1] = 2
        #expect(throws: ProtocolDecodeError.versionMismatch(2)) { try Message(frame: frame) }
    }

    @Test func rejectsUnknownType() throws {
        let frame = MessageHeader(rawType: 0x42, length: 0).encoded()
        #expect(throws: ProtocolDecodeError.unknownMessageType(0x42)) { try Message(frame: frame) }
    }

    @Test func rejectsTruncatedFrame() throws {
        let frame = try Message.faceBatch(FaceBatch(frames: [sampleFrame(0)])).encodedFrame()
        #expect(throws: ProtocolDecodeError.lengthMismatch) { try Message(frame: frame.dropLast()) }
    }

    @Test func rejectsBatchWithWrongFrameCount() throws {
        var payload = try Message.faceBatch(FaceBatch(frames: [sampleFrame(0)])).encodedPayload()
        payload[0] = 2
        #expect(throws: ProtocolDecodeError.lengthMismatch) { try Message(type: .faceBatch, payload: payload) }
    }

    @Test func rejectsOddAudioLength() throws {
        let payload = try Message.audioChunk(AudioChunk(ptsOfFirstSample: 0, samples: [1])).encodedPayload() + Data([0])
        #expect(throws: ProtocolDecodeError.lengthMismatch) { try Message(type: .audioChunk, payload: payload) }
    }

    @Test func rejectsOversizedHeader() {
        let header = MessageHeader(rawType: 0x10, length: MessageHeader.maxPayloadLength + 1).encoded()
        #expect(throws: ProtocolDecodeError.payloadTooLarge(MessageHeader.maxPayloadLength + 1)) {
            try MessageHeader(decoding: header)
        }
    }

    @Test func refusesToEncodeMalformedFrame() {
        var frame = sampleFrame(0)
        frame.blendShapes.removeLast()
        #expect(throws: ProtocolEncodeError.invalidFaceFrame) {
            try Message.faceBatch(FaceBatch(frames: [frame])).encodedPayload()
        }
    }
}

@Suite("Constants")
struct ConstantsTests {
    @Test func blendShapeOrderIsSortedAndComplete() {
        #expect(Constants.blendShapeOrder.count == Constants.blendShapeCount)
        #expect(Set(Constants.blendShapeOrder).count == Constants.blendShapeCount)
        #expect(Constants.blendShapeOrder == Constants.blendShapeOrder.sorted())
    }

    @Test func mouthBlendShapesResolve() {
        #expect(MouthBlendShapes.names.count == 29)
        #expect(Set(MouthBlendShapes.wireIndices).count == 29)
    }
}
