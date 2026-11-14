import AVFoundation
import TacitKit

/// Converts ARKit's microphone sample buffers to 16 kHz mono Int16 `AudioChunk`s.
///
/// The converter is cached and runs as a stream, so it holds back a few samples between buffers.
/// Each chunk's PTS is the input PTS minus what the converter still holds, which keeps chunk times
/// back to back. A new input format or a PTS jump over 1 ms resets the stream.
struct AudioResampler {
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: Constants.audioSampleRate,
                                             channels: 1, interleaved: true)!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var expectedInputPts: Double?
    /// Seconds fed in and taken out since the last reset.
    private var secondsIn = 0.0
    private var secondsOut = 0.0

    mutating func reset() {
        converter = nil
        inputFormat = nil
        expectedInputPts = nil
    }

    mutating func convert(_ sampleBuffer: CMSampleBuffer) -> AudioChunk? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard frameCount > 0, pts.isFinite,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        input.frameLength = AVAudioFrameCount(frameCount)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount),
                                                           into: input.mutableAudioBufferList) == noErr
        else { return nil }

        let isContinuous = expectedInputPts.map { abs(pts - $0) <= CaptureRecording.audioGapTolerance } ?? false
        if converter == nil || inputFormat != format || !isContinuous {
            guard let fresh = AVAudioConverter(from: format, to: outputFormat) else { return nil }
            fresh.downmix = true
            converter = fresh
            inputFormat = format
            secondsIn = 0
            secondsOut = 0
        }
        guard let converter else { return nil }

        let inputSeconds = Double(frameCount) / format.sampleRate
        let capacity = AVAudioFrameCount((inputSeconds * Constants.audioSampleRate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        let feed = OneShotInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let buffer = feed.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.int16ChannelData else { return nil }

        let held = secondsIn - secondsOut
        secondsIn += inputSeconds
        secondsOut += Double(output.frameLength) / Constants.audioSampleRate
        expectedInputPts = pts + inputSeconds
        guard output.frameLength > 0 else { return nil }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
        return AudioChunk(ptsOfFirstSample: pts - held, samples: samples)
    }
}

/// Hands the converter one buffer, then reports no more data until the next call.
private final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
