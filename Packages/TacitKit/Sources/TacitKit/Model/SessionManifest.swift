import Foundation

public enum SpeechStyle: String, Codable, Sendable, CaseIterable {
    case aloud, whisper, silent, negative
}

/// `manifest.json` in each session folder. Read by Swift and by `ml/silentml/data.py`.
public struct SessionManifest: Codable, Sendable, Equatable {
    public struct Device: Codable, Sendable, Equatable {
        public var model: String
        public var osVersion: String

        public init(model: String, osVersion: String) {
            self.model = model
            self.osVersion = osVersion
        }
    }

    public struct AppVersions: Codable, Sendable, Equatable {
        public var mac: String
        public var iphone: String

        public init(mac: String, iphone: String) {
            self.mac = mac
            self.iphone = iphone
        }
    }

    public struct Quality: Codable, Sendable, Equatable {
        public var ok: Bool
        public var flags: [String]

        public init(ok: Bool, flags: [String] = []) {
            self.ok = ok
            self.flags = flags
        }
    }

    public var sessionId: UUID
    public var createdAt: Date
    public var mode: SessionMode
    public var speechStyle: SpeechStyle
    public var promptId: String?
    public var promptText: String?
    public var commandId: String?
    /// Groups the takes of one Recorder sitting, so training can hold out whole sittings.
    public var sittingId: UUID?
    public var device: Device
    public var appVersions: AppVersions
    public var protocolVersion: UInt8
    public var featureSchemaVersion: UInt16
    public var firstFaceTs: Double?
    public var firstAudioTs: Double?
    public var frameCount: Int
    public var measuredFps: Double
    public var trackedRatio: Double
    public var droppedFrames: Int
    public var audioGapsFilled: Int
    public var measuredAvOffsetMs: Double?
    public var quality: Quality

    public init(sessionId: UUID, createdAt: Date, mode: SessionMode, speechStyle: SpeechStyle,
                promptId: String? = nil, promptText: String? = nil, commandId: String? = nil,
                sittingId: UUID? = nil, device: Device, appVersions: AppVersions,
                protocolVersion: UInt8 = Constants.protocolVersion,
                featureSchemaVersion: UInt16 = Constants.featureSchemaVersion,
                firstFaceTs: Double? = nil, firstAudioTs: Double? = nil,
                frameCount: Int = 0, measuredFps: Double = 0, trackedRatio: Double = 0,
                droppedFrames: Int = 0, audioGapsFilled: Int = 0, measuredAvOffsetMs: Double? = nil,
                quality: Quality = Quality(ok: true)) {
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.mode = mode
        self.speechStyle = speechStyle
        self.promptId = promptId
        self.promptText = promptText
        self.commandId = commandId
        self.sittingId = sittingId
        self.device = device
        self.appVersions = appVersions
        self.protocolVersion = protocolVersion
        self.featureSchemaVersion = featureSchemaVersion
        self.firstFaceTs = firstFaceTs
        self.firstAudioTs = firstAudioTs
        self.frameCount = frameCount
        self.measuredFps = measuredFps
        self.trackedRatio = trackedRatio
        self.droppedFrames = droppedFrames
        self.audioGapsFilled = audioGapsFilled
        self.measuredAvOffsetMs = measuredAvOffsetMs
        self.quality = quality
    }
}

extension SessionManifest {
    /// Copies the capture numbers into the manifest.
    public mutating func fill(from metrics: CaptureMetrics) {
        firstFaceTs = metrics.firstFaceTs
        firstAudioTs = metrics.firstAudioTs
        frameCount = metrics.frameCount
        measuredFps = metrics.measuredFps
        trackedRatio = metrics.trackedRatio
        droppedFrames = metrics.droppedFrames
        audioGapsFilled = metrics.audioGapsFilled
    }
}
