import simd

/// Picks `Constants.lipVertexIndices` from a neutral `ARFaceGeometry`. Used once, by the iPhone's
/// `LipVertexPickerView`, and the result is hardcoded.
///
/// The face mesh is open at the mouth, so the inner lip contour is the mesh boundary loop around
/// that hole. The selector finds it, keeps vertices inside a box around it and within `radius` of
/// it, then farthest-point samples `count` of them starting from the two mouth corners.
public enum LipVertexSelector {
    public struct Options: Sendable, Equatable {
        /// Maximum distance from the inner lip contour, metres.
        public var radius: Float = 0.006
        /// How far the mouth box extends past the contour, metres.
        public var boxMargin = SIMD3<Float>(0.006, 0.010, 0.010)
        public var count = Constants.lipVertexCount

        public init(radius: Float = 0.006, boxMargin: SIMD3<Float> = SIMD3(0.006, 0.010, 0.010),
                    count: Int = Constants.lipVertexCount) {
            self.radius = radius
            self.boxMargin = boxMargin
            self.count = count
        }
    }

    public struct Selection: Sendable, Equatable {
        /// `indices[0]` is the left mouth corner (lowest x), `indices[1]` the right one. The rest follow
        /// in sampling order. Step 3 measures mouth width between slots 0 and 1.
        public var indices: [Int]
        /// The inner lip contour, in loop order. For display.
        public var contour: [Int]
        /// Every vertex that passed the box and radius tests. For display.
        public var candidates: [Int]
    }

    public enum SelectionError: Error, Equatable, Sendable {
        case noMouthOpening
        case notEnoughCandidates(found: Int, needed: Int)
    }

    public static func select(vertices: [SIMD3<Float>], triangleIndices: [Int],
                              options: Options = Options()) throws(SelectionError) -> Selection {
        let contour = try mouthContour(vertices: vertices, triangleIndices: triangleIndices)
        let points = contour.map { vertices[$0] }

        let low = points.reduce(points[0], simd_min) - options.boxMargin
        let high = points.reduce(points[0], simd_max) + options.boxMargin
        let contourSet = Set(contour)
        let candidates = vertices.indices.filter { index in
            let p = vertices[index]
            guard all(p .>= low) && all(p .<= high) else { return false }
            return contourSet.contains(index) || distance(from: p, toLoop: points) <= options.radius
        }
        guard candidates.count >= options.count else {
            throw .notEnoughCandidates(found: candidates.count, needed: options.count)
        }

        let left = contour.min { vertices[$0].x < vertices[$1].x }!
        let right = contour.max { vertices[$0].x < vertices[$1].x }!
        let indices = farthestPointSample(candidates, seeds: [left, right], count: options.count, vertices: vertices)
        return Selection(indices: indices, contour: contour, candidates: candidates)
    }

    /// Boundary loops of the mesh, each in walking order. An edge is on the boundary when only one
    /// triangle uses it.
    static func boundaryLoops(triangleIndices: [Int]) -> [[Int]] {
        struct Edge: Hashable {
            let a, b: Int
            init(_ u: Int, _ v: Int) { (a, b) = u < v ? (u, v) : (v, u) }
        }
        var uses: [Edge: Int] = [:]
        for t in stride(from: 0, to: triangleIndices.count - 2, by: 3) {
            let (i, j, k) = (triangleIndices[t], triangleIndices[t + 1], triangleIndices[t + 2])
            for edge in [Edge(i, j), Edge(j, k), Edge(k, i)] { uses[edge, default: 0] += 1 }
        }
        var neighbours: [Int: [Int]] = [:]
        for (edge, count) in uses where count == 1 {
            neighbours[edge.a, default: []].append(edge.b)
            neighbours[edge.b, default: []].append(edge.a)
        }

        var loops: [[Int]] = []
        var visited = Set<Int>()
        for start in neighbours.keys.sorted() where !visited.contains(start) {
            var loop = [start]
            visited.insert(start)
            var previous = start
            var current = neighbours[start]!.min()!
            while current != start, !visited.contains(current) {
                loop.append(current)
                visited.insert(current)
                guard let next = neighbours[current]!.filter({ $0 != previous }).min() else { break }
                previous = current
                current = next
            }
            loops.append(loop)
        }
        return loops
    }

    /// The mouth hole: of the boundary loops other than the outer edge (the longest), the lowest one.
    static func mouthContour(vertices: [SIMD3<Float>], triangleIndices: [Int]) throws(SelectionError) -> [Int] {
        var loops = boundaryLoops(triangleIndices: triangleIndices).filter { $0.count >= 3 }
        guard loops.count >= 2 else { throw .noMouthOpening }
        loops.sort { $0.count > $1.count }
        loops.removeFirst()
        func centroidY(_ loop: [Int]) -> Float { loop.reduce(0) { $0 + vertices[$1].y } / Float(loop.count) }
        return loops.min { centroidY($0) < centroidY($1) }!
    }

    static func distance(from p: SIMD3<Float>, toLoop loop: [SIMD3<Float>]) -> Float {
        var best = Float.infinity
        for i in loop.indices {
            let a = loop[i]
            let b = loop[(i + 1) % loop.count]
            let ab = b - a
            let t = simd_clamp(simd_dot(p - a, ab) / max(simd_length_squared(ab), .leastNonzeroMagnitude), 0, 1)
            best = min(best, simd_distance(p, a + t * ab))
        }
        return best
    }

    /// Greedy farthest-point sampling. Ties go to the lower vertex index, so the result is deterministic.
    static func farthestPointSample(_ candidates: [Int], seeds: [Int], count: Int,
                                    vertices: [SIMD3<Float>]) -> [Int] {
        var chosen = seeds
        var nearest = candidates.map { c in seeds.map { simd_distance(vertices[c], vertices[$0]) }.min()! }
        while chosen.count < count {
            var bestSlot = 0
            for slot in nearest.indices where nearest[slot] > nearest[bestSlot] { bestSlot = slot }
            let pick = candidates[bestSlot]
            chosen.append(pick)
            for slot in nearest.indices {
                nearest[slot] = min(nearest[slot], simd_distance(vertices[candidates[slot]], vertices[pick]))
            }
        }
        return chosen
    }
}
