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
    /// The iPhone stops capturing on its own after this long without a `stop`.
    public static let maxCaptureDuration: TimeInterval = 120

    /// `ARFaceGeometry` topology. Capture refuses to start if the device reports anything else.
    public static let faceMeshVertexCount = 1_220

    public static let lipVertexCount = 64

    /// Indices into `ARFaceGeometry.vertices`, chosen once with `LipVertexPickerView` (M2).
    /// Slot 0 is the left mouth corner and slot 1 the right one (see `LipVertexSelector.Selection`).
    /// Never change after Step 1 data exists without bumping `featureSchemaVersion`.
    /// Picked on 2026-11-12 with a 9 mm radius, which reaches the outer edge of both lips,
    /// and reviewed on the live mesh. Mouth corners are vertices 249 and 684.
    public static let lipVertexIndices: [Int] = [
        249, 684, 21, 271, 706, 548, 99, 256, 688, 565, 116, 253, 550, 101, 672, 28,
        94, 559, 110, 713, 278, 690, 239, 556, 107, 26, 569, 120, 827, 397, 273, 237,
        698, 263, 545, 724, 542, 288, 541, 92, 240, 683, 248, 708, 722, 543, 238, 674,
        290, 553, 104, 93, 671, 1210, 96, 184, 1209, 633, 673, 25, 262, 697, 568, 681,
    ]

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
