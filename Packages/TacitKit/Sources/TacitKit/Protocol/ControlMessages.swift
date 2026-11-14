import Foundation

// JSON payloads for control messages. Field names match the spec's wire table.

public enum SessionMode: String, Codable, Sendable, CaseIterable {
    case record, dictate, command
}

public enum StreamKind: String, Codable, Sendable, CaseIterable {
    case face, audio
}

public struct Hello: Codable, Sendable, Equatable {
    /// Stable id of the sender (Keychain on both sides). Must match the id the peer paired with.
    public var deviceId: UUID
    public var deviceName: String
    public var deviceModel: String
    public var appVersion: String
    /// For example "18.2". Goes into each session manifest. Optional so older peers still decode.
    public var osVersion: String?
    public var protocolVersion: UInt8
    public var capabilities: [String]

    public init(deviceId: UUID, deviceName: String, deviceModel: String, appVersion: String, osVersion: String? = nil,
                protocolVersion: UInt8 = Constants.protocolVersion, capabilities: [String] = []) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.osVersion = osVersion
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
        /// `start` while the camera is in use by another Mac or the lip vertex picker.
        case busy
        /// The iPhone couldn't start or keep capturing (permission, ARKit failure, wrong mesh topology).
        case captureFailed
    }

    public var code: Code
    public var message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: Pairing

/// Mac → iPhone, only on the pairing listener, right after `hello`.
/// Carries the Mac's ephemeral X25519 public key. The long-term key comes from this exchange,
/// so someone who sniffs the pairing handshake and brute-forces the 6-digit code still can't recover it.
public struct PairRequest: Codable, Sendable, Equatable {
    public var publicKey: Data

    public init(publicKey: Data) {
        self.publicKey = publicKey
    }
}

/// iPhone → Mac, reply to `pairRequest`. The iPhone has stored the long-term key when it sends this.
public struct PairAccept: Codable, Sendable, Equatable {
    public var publicKey: Data

    public init(publicKey: Data) {
        self.publicKey = publicKey
    }
}

/// Both directions. The sender has deleted its key for the receiver. The receiver deletes its key too.
public struct Forget: Codable, Sendable, Equatable {
    public init() {}
}
