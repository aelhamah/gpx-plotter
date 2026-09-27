import Foundation

/// One position report, decoupled from CoreLocation's `CLLocation`.
public struct LocationFix: Equatable, Sendable {
    public var lon: Double
    public var lat: Double
    public var accuracyMeters: Double
    public var timestamp: Date

    public init(lon: Double, lat: Double, accuracyMeters: Double, timestamp: Date = .init(timeIntervalSince1970: 0)) {
        self.lon = lon
        self.lat = lat
        self.accuracyMeters = accuracyMeters
        self.timestamp = timestamp
    }

    public var coordinate: Coordinate {
        get { Coordinate(lat: lat, lon: lon) }
        set {
            lat = newValue.lat
            lon = newValue.lon
        }
    }
}

/// Accuracy-halo geometry, ported from `web/src/locate.ts`. A geodesic ring
/// rather than a zoom-scaled circle layer keeps the halo honest about how far
/// the fix can be off at any zoom.
public enum AccuracyHalo {
    /// How wide the accuracy circle should be on screen when the camera moves to the fix.
    public static let targetAccuracyPixels = 60.0
    /// Web Mercator ground resolution at the equator, in meters per pixel at zoom 0.
    static let metersPerPixelAtZoom0 = 156_543.03392
    static let defaultAccuracyMeters = 30.0
    static let minLatitudeForScale = 1.0

    /// Closed ring of `radiusMeters` around a point, `steps` + 1 vertices with the
    /// last repeating the first.
    public static func ring(
        lon: Double,
        lat: Double,
        radiusMeters: Double,
        steps: Int = 64
    ) -> [Coordinate] {
        let distance = max(0, radiusMeters)
        let latRad = lat * .pi / 180
        let sinLat = sin(latRad)
        let cosLat = cos(latRad)
        let angular = distance / Haversine.earthRadiusMeters
        var ring: [Coordinate] = []
        ring.reserveCapacity(steps + 1)
        for step in 0...steps {
            let bearing = (Double(step) / Double(steps)) * .pi * 2
            let sinLat2 = sinLat * cos(angular) + cosLat * sin(angular) * cos(bearing)
            let lat2 = asin(min(1, max(-1, sinLat2)))
            let lon2 = atan2(sin(bearing) * sin(angular) * cosLat, cos(angular) - sinLat * sinLat2)
            ring.append(Coordinate(lat: lat2 * 180 / .pi, lon: wrapLongitude(lon + lon2 * 180 / .pi)))
        }
        return ring
    }

    /// Zoom that frames the accuracy halo in roughly `targetAccuracyPixels` pixels,
    /// clamped to `maxZoom`. A bad (or missing) accuracy reading falls back to a
    /// street-level zoom so the dot is still worth showing.
    public static func zoom(forAccuracyMeters accuracyMeters: Double, latitude: Double, maxZoom: Double = 15) -> Double {
        let accuracy = accuracyMeters.isFinite && accuracyMeters > 0
            ? accuracyMeters
            : defaultAccuracyMeters
        let clampedLat = max(-90 + minLatitudeForScale, min(90 - minLatitudeForScale, latitude))
        let scale = cos(clampedLat * .pi / 180)
        let zoom = log2((targetAccuracyPixels * metersPerPixelAtZoom0 * abs(scale)) / accuracy)
        return (min(maxZoom, max(2, zoom)) * 10).rounded() / 10
    }

    static func wrapLongitude(_ lon: Double) -> Double {
        ((((lon + 180).truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)) - 180
    }
}