import Foundation

public enum Haversine {
    /// Mean Earth radius, matching `web/src/geo.ts` so distances match the web app exactly.
    public static let earthRadiusMeters = 6_371_008.8

    public static func meters(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.lat * .pi / 180
        let lat2 = b.lat * .pi / 180
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let sinLat = sin(dLat / 2)
        let sinLon = sin(dLon / 2)
        let h = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }

    public static func meters(from a: RoutePoint, to b: RoutePoint) -> Double {
        meters(from: a.coordinate, to: b.coordinate)
    }

    public static func routeLength(_ points: [RoutePoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<points.count {
            total += meters(from: points[index - 1], to: points[index])
        }
        return total
    }
}

public struct ElevationStats: Equatable, Sendable {
    public var gain: Double?
    public var loss: Double?
    public var min: Double?
    public var max: Double?

    public init(gain: Double? = nil, loss: Double? = nil, min: Double? = nil, max: Double? = nil) {
        self.gain = gain
        self.loss = loss
        self.min = min
        self.max = max
    }
}

public struct ProfileSummary: Equatable, Sendable {
    public var gain: Double?
    public var loss: Double?
    public var min: Double?
    public var max: Double?
    public var maxSlope: Double?

    public init(
        gain: Double? = nil,
        loss: Double? = nil,
        min: Double? = nil,
        max: Double? = nil,
        maxSlope: Double? = nil
    ) {
        self.gain = gain
        self.loss = loss
        self.min = min
        self.max = max
        self.maxSlope = maxSlope
    }
}

public enum Slope {
    /// Absolute terrain angle of each route segment, in degrees. `nil` when either
    /// elevation is unknown or the vertices are coincident.
    public static func degrees(from a: RoutePoint, to b: RoutePoint) -> Double? {
        guard let aElevation = a.elevation, let bElevation = b.elevation,
              aElevation.isFinite, bElevation.isFinite
        else { return nil }
        let horizontal = Haversine.meters(from: a, to: b)
        if horizontal < 0.01 { return nil }
        return atan2(abs(bElevation - aElevation), horizontal) * 180 / .pi
    }

    /// Elevation statistics over the route's own vertices.
    public static func stats(for points: [RoutePoint]) -> ElevationStats {
        let elevations = points.compactMap(\.elevation).filter(\.isFinite)
        guard !elevations.isEmpty else { return ElevationStats() }
        var gain = 0.0
        var loss = 0.0
        for index in 1..<elevations.count {
            let delta = elevations[index] - elevations[index - 1]
            if delta > 0 { gain += delta } else if delta < 0 { loss += -delta }
        }
        return ElevationStats(
            gain: gain,
            loss: loss,
            min: elevations.min(),
            max: elevations.max()
        )
    }

    /// Elevation statistics over a dense terrain profile (the output of
    /// `Profile.routeSamples` with elevations filled from the DEM). Accumulates
    /// gain and loss sample-to-sample and tracks the steepest segment angle, so
    /// the numbers reflect the terrain crossed *between* route vertices.
    public static func summary(for profile: [RoutePoint]) -> ProfileSummary {
        let valid = profile.compactMap { point -> RoutePoint? in
            guard let elevation = point.elevation, elevation.isFinite else { return nil }
            return point
        }
        guard valid.count >= 2 else { return ProfileSummary() }

        var gain = 0.0
        var loss = 0.0
        var maxSlope: Double?
        for index in 1..<valid.count {
            let delta = valid[index].elevation! - valid[index - 1].elevation!
            if delta > 0 { gain += delta } else if delta < 0 { loss += -delta }
            if let slope = degrees(from: valid[index - 1], to: valid[index]),
               maxSlope == nil || slope > maxSlope! {
                maxSlope = slope
            }
        }
        return ProfileSummary(
            gain: gain,
            loss: loss,
            min: valid.compactMap(\.elevation).min(),
            max: valid.compactMap(\.elevation).max(),
            maxSlope: maxSlope
        )
    }
}