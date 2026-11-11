import Foundation

// JSON payloads for control messages. Field names match the spec's wire table.

public enum SessionMode: String, Codable, Sendable, CaseIterable {
    case record, dictate, command
}

public enum StreamKind: String, Codable, Sendable, CaseIterable {
    case face, audio
}

public struct Hello: Codable, Sendable, Equatable {
    public var deviceName: String
    public var deviceModel: String
    public var appVersion: String
    public var protocolVersion: UInt8
    public var capabilities: [String]

    public init(deviceName: String, deviceModel: String, appVersion: String,
                protocolVersion: UInt8 = Constants.protocolVersion, capabilities: [String] = []) {
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

public struct StartCapture: Codable, Sendable, Equatable {
    public var sessionId: UUID
    public var mode: SessionMode
    public var streams: [StreamKind]
    public var promptText: String?

    public init(sessionId: UUID, mode: SessionMode, streams: [StreamKind] = [.face, .audio], promptText: String? = nil) {
        self.sessionId = sessionId
        self.mode = mode
        self.streams = streams
        self.promptText = promptText
    }
}

public struct StopCapture: Codable, Sendable, Equatable {
    public var sessionId: UUID

    public init(sessionId: UUID) {
        self.sessionId = sessionId
    }
}

public struct DeviceStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case unpaired, idle, capturing, error
    }

    public enum TrackingState: String, Codable, Sendable {
        case notAvailable, limited, normal
    }

    public enum ThermalState: String, Codable, Sendable {
        case nominal, fair, serious, critical
    }

    public var state: State
    public var trackingState: TrackingState
    public var faceDetected: Bool
    public var thermalState: ThermalState
    public var batteryLevel: Float
    public var isCharging: Bool

    public init(state: State, trackingState: TrackingState, faceDetected: Bool,
                thermalState: ThermalState, batteryLevel: Float, isCharging: Bool) {
        self.state = state
        self.trackingState = trackingState
        self.faceDetected = faceDetected
        self.thermalState = thermalState
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
    }
}

/// Used by both `clockPing` and `clockPong`. The pinger fills `t0`, the ponger adds `t1` (receive) and `t2` (send).
public struct ClockSync: Codable, Sendable, Equatable {
    public var t0: Double
    public var t1: Double?
    public var t2: Double?

    public init(t0: Double, t1: Double? = nil, t2: Double? = nil) {
        self.t0 = t0
        self.t1 = t1
        self.t2 = t2
    }
}

public struct ProtocolErrorMessage: Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable {
        case versionMismatch, unknownMessageType, malformedPayload, notPaired, unsupported, internalError
    }

    public var code: Code
    public var message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}
