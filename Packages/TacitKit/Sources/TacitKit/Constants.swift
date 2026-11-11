import Foundation

public enum Constants {
    /// Wire protocol version carried in every frame header. Peers reject mismatches.
    public static let protocolVersion: UInt8 = 1

    /// Bumped whenever the face record layout or `lipVertexIndices` change.
    /// Training must never mix sessions with different schema versions.
    public static let featureSchemaVersion: UInt16 = 1

    public static let bonjourServiceType = "_tacittype._tcp"
    public static let logSubsystem = "com.tacittype"

    public static let audioSampleRate: Double = 16_000
    public static let faceBatchInterval: TimeInterval = 0.1

    /// `ARFaceGeometry` topology. Capture refuses to start if the device reports anything else.
    public static let faceMeshVertexCount = 1_220

    public static let lipVertexCount = 64

    /// Indices into `ARFaceGeometry.vertices`, chosen once with `LipVertexPickerView` (M2).
    /// Never change after Step 1 data exists without bumping `featureSchemaVersion`.
    public static let lipVertexIndices: [Int] = []

    /// `ARFaceAnchor.BlendShapeLocation` raw values sorted by code point.
    /// This is the on-wire and on-disk order. `ml/silentml/constants.py` mirrors it and a pytest checks parity.
    public static let blendShapeOrder: [String] = [
        "browDown_L", "browDown_R", "browInnerUp", "browOuterUp_L", "browOuterUp_R",
        "cheekPuff", "cheekSquint_L", "cheekSquint_R",
        "eyeBlink_L", "eyeBlink_R", "eyeLookDown_L", "eyeLookDown_R", "eyeLookIn_L", "eyeLookIn_R",
        "eyeLookOut_L", "eyeLookOut_R", "eyeLookUp_L", "eyeLookUp_R", "eyeSquint_L", "eyeSquint_R",
        "eyeWide_L", "eyeWide_R",
        "jawForward", "jawLeft", "jawOpen", "jawRight",
        "mouthClose", "mouthDimple_L", "mouthDimple_R", "mouthFrown_L", "mouthFrown_R", "mouthFunnel",
        "mouthLeft", "mouthLowerDown_L", "mouthLowerDown_R", "mouthPress_L", "mouthPress_R", "mouthPucker",
        "mouthRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
        "mouthSmile_L", "mouthSmile_R", "mouthStretch_L", "mouthStretch_R", "mouthUpperUp_L", "mouthUpperUp_R",
        "noseSneer_L", "noseSneer_R",
        "tongueOut",
    ]

    public static let blendShapeCount = 52
}
