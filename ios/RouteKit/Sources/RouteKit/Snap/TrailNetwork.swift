import Foundation

/// Pure routing along a set of trail polylines. Used to make a drawn route run
/// *along* a trail between two snapped points instead of cutting straight
/// across.
///
/// Port of the web app's `web/src/trailGraph.ts`, tunables verbatim.
///
/// The polylines come from vector tiles; a single OSM way is often split into
/// several features, so loose endpoints within `TRAIL_JOIN_METERS` are bridged.
/// A Dijkstra search then finds the shortest chain of trail vertices between
/// the two points. Anything that is not meaningfully shorter than a straight
/// line (or simply unreachable) returns nil, leaving the caller to draw
/// straight.
public enum TrailNetwork {
    /// Loose trail ends closer than this are treated as connected (way splits).
    public static let joinMeters = 25.0
    /// Refuse a routed path longer than this multiple of the straight-line
    /// distance.
    public static let maxDetour = 4.0
    static let maxVertices = 20_000

    struct Edge {
        var to: Int
        var w: Double
    }

    static func coordKey(_ p: Coordinate) -> String {
        String(format: "%.6f,%.6f", p.lat, p.lon)
    }

    /// Drop exact-duplicate polylines (the same trail can appear in two
    /// tilesets).
    public static func dedupeTrailLines(_ lines: [[Coordinate]]) -> [[Coordinate]] {
        var seen = Set<String>()
        var out: [[Coordinate]] = []
        for line in lines {
            if line.count < 2 { continue }
            let key = line.map(coordKey).joined(separator: "|")
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(line)
        }
        return out
    }

    /// A binary min-heap over (node, dist), as in the web decoder. A hand-rolled
    /// heap rather than a sorted array: the graph over a z15 tile ring can be
    /// thousands of nodes, and re-sorting per push is the quadratic that made
    /// the web version measure `MAX_VERTICES` in the first place.
    struct MinHeap {
        private var items: [(node: Int, dist: Double)] = []

        mutating func push(_ node: Int, _ dist: Double) {
            items.append((node, dist))
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) >> 1
                if items[parent].dist <= items[i].dist { break }
                items.swapAt(parent, i)
                i = parent
            }
        }

        mutating func pop() -> (node: Int, dist: Double)? {
            guard !items.isEmpty else { return nil }
            let top = items[0]
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var i = 0
                while true {
                    let left = i * 2 + 1
                    let right = left + 1
                    var smallest = i
                    if left < items.count && items[left].dist < items[smallest].dist { smallest = left }
                    if right < items.count && items[right].dist < items[smallest].dist { smallest = right }
                    if smallest == i { break }
                    items.swapAt(smallest, i)
                    i = smallest
                }
            }
            return top
        }

        var isEmpty: Bool { items.isEmpty }
    }

    /// Shortest path along the trail network from `start` to `end`, both taken
    /// as already-projected points on the network. Returns the vertex chain
    /// (starting and ending at the projections), or nil when there is no useful
    /// path.
    public static func routeAlongTrails(
        _ lines: [[Coordinate]],
        start: Coordinate,
        end: Coordinate
    ) -> [Coordinate]? {
        let unique = dedupeTrailLines(lines)
        if unique.isEmpty { return nil }

        var nodes: [Coordinate] = []
        var nodeIndex: [String: Int] = [:]
        var edges: [[Edge]] = []
        var endpoints: [Int] = []

        func addNode(_ p: Coordinate) -> Int {
            let key = coordKey(p)
            if let index = nodeIndex[key] { return index }
            let index = nodes.count
            nodeIndex[key] = index
            nodes.append(p)
            edges.append([])
            return index
        }
        func addEdges(_ i: Int, _ j: Int) {
            if i == j { return }
            edges[i].append(Edge(to: j, w: flatDistanceMeters(nodes[i], nodes[j])))
        }

        var vertices = 0
        for line in unique {
            var previous = -1
            for point in line {
                let index = addNode(point)
                if previous >= 0 {
                    addEdges(previous, index)
                    addEdges(index, previous)
                }
                previous = index
                vertices += 1
            }
            endpoints.append(contentsOf: [addNode(line[0]), addNode(line[line.count - 1])])
            if vertices > maxVertices { return nil }
        }

        // Bridge loose way endpoints so a split OSM way still routes as one
        // trail.
        let uniqueEndpoints = Array(Set(endpoints))
        for i in 0..<uniqueEndpoints.count {
            for j in (i + 1)..<uniqueEndpoints.count {
                let a = uniqueEndpoints[i]
                let b = uniqueEndpoints[j]
                if flatDistanceMeters(nodes[a], nodes[b]) <= joinMeters {
                    addEdges(a, b)
                    addEdges(b, a)
                }
            }
        }

        guard let startMatch = nearestLine(start, unique, .infinity),
              let endMatch = nearestLine(end, unique, .infinity),
              startMatch.result.segment != nil,
              endMatch.result.segment != nil
        else { return nil }
        if flatDistanceMeters(startMatch.result.point, endMatch.result.point) < 1 { return nil }

        let source = addNode(startMatch.result.point)
        let target = addNode(endMatch.result.point)
        for (index, match) in [(source, startMatch), (target, endMatch)] {
            for bridge in [match.result.segment!.a, match.result.segment!.b] {
                let node = addNode(bridge)
                addEdges(index, node)
                addEdges(node, index)
            }
        }
        if source == target { return nil }

        var dist = [Double](repeating: .infinity, count: nodes.count)
        var prev = [Int](repeating: -1, count: nodes.count)
        var settled = [Bool](repeating: false, count: nodes.count)
        dist[source] = 0
        var heap = MinHeap()
        heap.push(source, 0)
        while let current = heap.pop() {
            if settled[current.node] { continue }
            settled[current.node] = true
            if current.node == target { break }
            for edge in edges[current.node] {
                let next = current.dist + edge.w
                if next < dist[edge.to] {
                    dist[edge.to] = next
                    prev[edge.to] = current.node
                    heap.push(edge.to, next)
                }
            }
        }
        guard dist[target].isFinite else { return nil }

        let straight = flatDistanceMeters(startMatch.result.point, endMatch.result.point)
        if dist[target] > maxDetour * straight { return nil }

        var path: [Coordinate] = []
        var node = target
        while node != -1 {
            path.append(nodes[node])
            node = prev[node]
        }
        path.reverse()
        return path
    }

    /// The trail vertices to splice between two route points so the route runs
    /// *along* the trail instead of cutting straight across it.
    ///
    /// `to` is a point the caller has already snapped onto the trail; `from` is
    /// the previous drawn point, which is only usable if it snapped too.
    /// `radiusMeters` must be the same radius that snap used — a point snapped
    /// onto a trail *is* on that trail, so testing it against anything tighter
    /// refuses legs whose endpoints were placed correctly.
    ///
    /// Returns the interior vertices, excluding both endpoints, so the caller
    /// can splice them in without duplicating either. Empty means "draw a
    /// straight segment", which is the right answer when there is no usable
    /// trail between the two points.
    public static func trailVerticesBetween(
        _ lines: [[Coordinate]],
        from: Coordinate,
        to: Coordinate,
        radiusMeters: Double
    ) -> [Coordinate] {
        guard let fromMatch = nearestLine(from, lines, radiusMeters) else { return [] }
        guard let path = routeAlongTrails(lines, start: fromMatch.result.point, end: to), path.count > 2 else { return [] }
        return Array(path[1..<(path.count - 1)])
    }
}
