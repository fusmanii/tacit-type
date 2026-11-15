import simd

/// Picks `Constants.cropLandmarkIndices` from a neutral `ARFaceGeometry`.
///
/// The face mesh has holes for the eyes and the mouth. Eye corners are the low-x and high-x ends of
/// the two eye holes. The lip centres are the midline points of the mouth hole. Nose and chin points
/// come from the midline (|x| under `midlineTolerance`): the tip is the most forward point between
/// the eyes and the mouth, the bridge is the front surface a third of the way from the eyes to the tip,
/// the base is the deepest point between the tip and the upper lip, and the chin is the lowest point.
/// Mouth corners are `lipVertexIndices` slots 0 and 1, so both lists agree.
public enum CropLandmarkSelector {
    public enum SelectionError: Error, Equatable, Sendable {
        case holesNotFound(found: Int)
        case midlineNotFound(CropLandmark)
    }

    public static let midlineTolerance: Float = 0.004

    public static func select(vertices: [SIMD3<Float>], triangleIndices: [Int],
                              mouthCorners: (low: Int, high: Int)? = nil) throws(SelectionError) -> [Int] {
        var loops = LipVertexSelector.boundaryLoops(triangleIndices: triangleIndices).filter { $0.count >= 3 }
        guard loops.count >= 4 else { throw .holesNotFound(found: max(0, loops.count - 1)) }
        loops.sort { $0.count > $1.count }
        loops.removeFirst()

        func centroid(_ loop: [Int]) -> SIMD3<Float> { loop.reduce(.zero) { $0 + vertices[$1] } / Float(loop.count) }
        loops.sort { centroid($0).y < centroid($1).y }
        let mouth = loops[0]
        let eyes = loops.suffix(2).sorted { centroid($0).x < centroid($1).x }
        let (eyeLow, eyeHigh) = (eyes[0], eyes[1])

        func lowestX(_ loop: [Int]) -> Int { loop.min { vertices[$0].x < vertices[$1].x }! }
        func highestX(_ loop: [Int]) -> Int { loop.max { vertices[$0].x < vertices[$1].x }! }

        let corners = mouthCorners ?? (lowestX(mouth), highestX(mouth))
        let mouthCentre = centroid(mouth)
        func nearestMidline(_ candidates: [Int], _ slot: CropLandmark) throws(SelectionError) -> Int {
            guard let best = candidates.min(by: { abs(vertices[$0].x) < abs(vertices[$1].x) }) else {
                throw .midlineNotFound(slot)
            }
            return best
        }
        let upperLip = try nearestMidline(mouth.filter { vertices[$0].y > mouthCentre.y }, .upperLipCentre)
        let lowerLip = try nearestMidline(mouth.filter { vertices[$0].y <= mouthCentre.y }, .lowerLipCentre)

        let midline = vertices.indices.filter { abs(vertices[$0].x) < midlineTolerance }
        let eyeY = (centroid(eyeLow).y + centroid(eyeHigh).y) / 2
        func pick(_ slot: CropLandmark, where test: (SIMD3<Float>) -> Bool,
                  by better: (SIMD3<Float>, SIMD3<Float>) -> Bool) throws(SelectionError) -> Int {
            guard let best = midline.filter({ test(vertices[$0]) }).min(by: { better(vertices[$0], vertices[$1]) }) else {
                throw .midlineNotFound(slot)
            }
            return best
        }

        let tip = try pick(.noseTip, where: { $0.y > mouthCentre.y && $0.y < eyeY }, by: { $0.z > $1.z })
        let tipY = vertices[tip].y
        let bridgeY = eyeY + (tipY - eyeY) / 3
        let bridge = try pick(.noseBridge, where: { abs($0.y - bridgeY) < 0.004 }, by: { $0.z > $1.z })
        let upperY = vertices[upperLip].y
        let base = try pick(.noseBase, where: { $0.y > upperY && $0.y < tipY }, by: { $0.z < $1.z })
        let chin = try pick(.chin, where: { $0.y < mouthCentre.y }, by: { $0.y < $1.y })

        var slots = [Int](repeating: 0, count: CropLandmark.allCases.count)
        slots[CropLandmark.eyeOuterLowX.rawValue] = lowestX(eyeLow)
        slots[CropLandmark.eyeInnerLowX.rawValue] = highestX(eyeLow)
        slots[CropLandmark.eyeInnerHighX.rawValue] = lowestX(eyeHigh)
        slots[CropLandmark.eyeOuterHighX.rawValue] = highestX(eyeHigh)
        slots[CropLandmark.noseBridge.rawValue] = bridge
        slots[CropLandmark.noseTip.rawValue] = tip
        slots[CropLandmark.noseBase.rawValue] = base
        slots[CropLandmark.mouthCornerLowX.rawValue] = corners.low
        slots[CropLandmark.mouthCornerHighX.rawValue] = corners.high
        slots[CropLandmark.upperLipCentre.rawValue] = upperLip
        slots[CropLandmark.lowerLipCentre.rawValue] = lowerLip
        slots[CropLandmark.chin.rawValue] = chin
        return slots
    }

    /// The hardcoded corners, when `lipVertexIndices` exists.
    public static var lipCorners: (low: Int, high: Int)? {
        Constants.lipVertexIndices.count >= 2 ? (Constants.lipVertexIndices[0], Constants.lipVertexIndices[1]) : nil
    }
}
