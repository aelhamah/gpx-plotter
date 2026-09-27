import Foundation

/// Great-circle-free meter distance between two points (flat at local scale).
public func flatDistanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
    let midLat = ((a.lat + b.lat) / 2) * (.pi / 180)
    let dx = (b.lon - a.lon) * 111320 * cos(midLat)
    let dy = (b.lat - a.lat) * 110574
    return sqrt(dx * dx + dy * dy)
}

public func flatDistanceMeters(_ a: RoutePoint, _ b: RoutePoint) -> Double {
    flatDistanceMeters(a.coordinate, b.coordinate)
}

/// Closest point on segment [a, b] to p (linear interpolation in lon/lat).
public func projectToSegment(_ p: Coordinate, _ a: Coordinate, _ b: Coordinate) -> Coordinate {
    let midLat = ((a.lat + b.lat) / 2) * (.pi / 180)
    let lonScale = cos(midLat)
    let ax = a.lon * lonScale
    let ay = a.lat
    let bx = b.lon * lonScale
    let by = b.lat
    let px = p.lon * lonScale
    let py = p.lat
    let abx = bx - ax
    let aby = by - ay
    let apx = px - ax
    let apy = py - ay
    let ab2 = abx * abx + aby * aby
    let t = ab2 == 0 ? 0 : max(0, min(1, (apx * abx + apy * aby) / ab2))
    return Coordinate(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
}

public struct SnapResult: Equatable, Sendable {
    public var point: Coordinate
    public var distanceMeters: Double
    /// The segment the point was projected onto (absent for single-point lines).
    public var segment: SnapSegment?

    public init(point: Coordinate, distanceMeters: Double, segment: SnapSegment? = nil) {
        self.point = point
        self.distanceMeters = distanceMeters
        self.segment = segment
    }
}

public struct SnapSegment: Equatable, Sendable {
    public var a: Coordinate
    public var b: Coordinate
    /// Position of the projection along the segment, 0..1.
    public var t: Double

    public init(a: Coordinate, b: Coordinate, t: Double) {
        self.a = a
        self.b = b
        self.t = t
    }
}

/// Nearest point on a polyline to `p`, within `maxMeters`. Returns nil if no point is close enough.
public func nearestOnLine(_ p: Coordinate, _ line: [Coordinate], _ maxMeters: Double) -> SnapResult? {
    if line.isEmpty { return nil }
    if line.count == 1 {
        let distance = flatDistanceMeters(p, line[0])
        return distance <= maxMeters ? SnapResult(point: line[0], distanceMeters: distance) : nil
    }

    var best: SnapResult?
    for i in 0..<(line.count - 1) {
        let a = line[i]
        let b = line[i + 1]
        let point = projectToSegment(p, a, b)
        let distance = flatDistanceMeters(p, point)
        if distance <= maxMeters && (best == nil || distance < best!.distanceMeters) {
            let midLat = ((a.lat + b.lat) / 2) * (.pi / 180)
            let lonScale = cos(midLat)
            let abx = (b.lon - a.lon) * lonScale
            let aby = b.lat - a.lat
            let ab2 = abx * abx + aby * aby
            let apx = (point.lon - a.lon) * lonScale
            let apy = point.lat - a.lat
            let t = ab2 == 0 ? 0 : max(0, min(1, (apx * abx + apy * aby) / ab2))
            best = SnapResult(point: point, distanceMeters: distance, segment: SnapSegment(a: a, b: b, t: t))
        }
    }
    return best
}