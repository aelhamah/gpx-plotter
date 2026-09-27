import Foundation

/// Web-Mercator helpers so profile samples follow the straight lines drawn on the map.
public enum Mercator {
    public static func x(_ lon: Double) -> Double {
        (lon + 180) / 360
    }

    public static func y(_ lat: Double) -> Double {
        let sinLat = sin(lat * .pi / 180)
        return 0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * .pi)
    }

    /// Inverse of `y(_:)`/`x(_:)`, taking the normalized axes in MapLibre's order.
    public static func coordinate(y mercatorY: Double, x mercatorX: Double) -> Coordinate {
        Coordinate(
            lat: atan(sinh(.pi * (1 - 2 * mercatorY))) * (180 / .pi),
            lon: mercatorX * 360 - 180
        )
    }

    /// Web Mercator position in 512-point world units, the scale MapLibre's transform uses.
    public static func world(lon: Double, lat: Double, zoom: Double) -> (x: Double, y: Double) {
        let world = 512 * pow(2, zoom)
        let sinLat = sin(lat * .pi / 180)
        return (
            x: ((lon + 180) / 360) * world,
            y: (0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * .pi)) * world
        )
    }
}

public enum Profile {
    /// "Nice" even spacing between x-axis ticks, aimed at ~5 divisions along the route.
    public static func axisStep(totalMeters: Double) -> Double {
        let raw = totalMeters / 5
        if raw <= 0 { return 0 }
        let magnitude = pow(10, floor(log10(raw)))
        let norm = raw / magnitude
        return (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * magnitude
    }

    /// Closest profile sample index to a cumulative distance, for chart selection.
    public static func nearestSample(cumulative: [Double], to target: Double) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for index in cumulative.indices {
            let distance = abs(cumulative[index] - target)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Resample the route at a fixed ground spacing so elevation stats reflect the
    /// terrain crossed along the lines between points, not just the vertices. Short
    /// segments are kept as-is; long segments are interpolated along their drawn
    /// (Mercator-straight) path. Interpolated samples carry no elevation, so
    /// callers fill them from the DEM before computing stats.
    public static func routeSamples(_ points: [RoutePoint], stepMeters: Double) -> [RoutePoint] {
        guard let last = points.last else { return [] }
        var profile: [RoutePoint] = []
        profile.reserveCapacity(points.count)
        for index in 1..<points.count {
            let a = points[index - 1]
            let b = points[index]
            profile.append(a)
            let length = Haversine.meters(from: a, to: b)
            if length <= stepMeters { continue }
            let steps = Int((length / stepMeters).rounded())
            var ax = Mercator.x(a.lon)
            let ay = Mercator.y(a.lat)
            var bx = Mercator.x(b.lon)
            let by = Mercator.y(b.lat)
            // antimeridian wrap
            if bx - ax > 0.5 { bx -= 1 } else if bx - ax < -0.5 { bx += 1 }
            for step in 1..<steps {
                let t = Double(step) / Double(steps)
                let coordinate = Mercator.coordinate(
                    y: ay + (by - ay) * t,
                    x: ax + (bx - ax) * t
                )
                profile.append(RoutePoint(coordinate))
            }
        }
        profile.append(last)
        return profile
    }
}