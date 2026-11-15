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

    // MARK: Mouth video (M3b)

    /// Side of the square grayscale mouth crop the iPhone sends, pixels.
    public static let mouthCropSize = 192
    /// Both lip-reading models were trained on 25 fps video.
    public static let mouthFps: Double = 25
    public static let mouthBatchInterval: TimeInterval = 0.2
    /// The crop square's side as a multiple of the mouth width (corner to corner).
    public static let mouthCropScale: Float = 3
    public static let mouthJPEGQuality = 0.85
    /// Version of the `mouth.bin` layout. Bump on any change.
    public static let mouthFileVersion: UInt16 = 1

    /// Face-mesh vertices projected into the camera image each mouth frame, in `CropLandmark` slot order.
    /// Chosen by `CropLandmarkSelector` on ARKit's neutral face and reviewed with `LipVertexPickerView`.
    /// Mouth corners are fixed to `lipVertexIndices` slots 0 and 1.
    /// Picked on 2026-11-15 and reviewed on the live mesh. Never change after mouth data exists
    /// without bumping `mouthFileVersion`, since `mouth.bin` landmarks mean these vertices.
    /// Slots: eyeOuterLowX, eyeInnerLowX, eyeInnerHighX, eyeOuterHighX, noseBridge, noseTip, noseBase,
    /// mouthCornerLowX, mouthCornerHighX, upperLipCentre, lowerLipCentre, chin
    public static let cropLandmarkIndices: [Int] = [
        1101, 1089, 1081, 1069, 12, 8, 256, 249, 684, 691, 25, 1047,
    ]

    public static var cropLandmarkCount: Int { CropLandmark.allCases.count }
}

/// The 12 crop landmark slots, in wire and `mouth.bin` order.
///
/// "Low x" and "high x" are face-local x, as in `LipVertexSelector` (slot 0 there is the low-x corner).
/// Between them they cover the 68-point iBUG positions the lip-reading models align with:
/// eye corners 36, 39, 42, 45, nose 28, 30, 33, mouth corners 48 and 54, and the mouth centre.
public enum CropLandmark: Int, CaseIterable, Sendable {
    case eyeOuterLowX, eyeInnerLowX, eyeInnerHighX, eyeOuterHighX
    case noseBridge, noseTip, noseBase
    case mouthCornerLowX, mouthCornerHighX, upperLipCentre, lowerLipCentre
    case chin
}
