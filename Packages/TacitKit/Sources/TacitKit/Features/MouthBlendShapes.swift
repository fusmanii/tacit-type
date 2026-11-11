/// The 29 mouth and jaw blendshapes used by the mouth-activity gate (Step 2) and command features (Step 3).
/// Order here is the feature order, not the wire order.
public enum MouthBlendShapes {
    public static let names: [String] = [
        "jawOpen", "jawForward", "jawLeft", "jawRight",
        "mouthClose", "mouthFunnel", "mouthPucker", "mouthLeft", "mouthRight",
        "mouthSmile_L", "mouthSmile_R", "mouthFrown_L", "mouthFrown_R",
        "mouthDimple_L", "mouthDimple_R", "mouthStretch_L", "mouthStretch_R",
        "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
        "mouthPress_L", "mouthPress_R", "mouthLowerDown_L", "mouthLowerDown_R",
        "mouthUpperUp_L", "mouthUpperUp_R",
        "cheekPuff", "tongueOut",
    ]

    /// Positions of `names` inside `Constants.blendShapeOrder`.
    public static let wireIndices: [Int] = names.map { name in
        guard let index = Constants.blendShapeOrder.firstIndex(of: name) else {
            preconditionFailure("\(name) missing from Constants.blendShapeOrder")
        }
        return index
    }
}
