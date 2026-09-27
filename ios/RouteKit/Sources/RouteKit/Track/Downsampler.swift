import Foundation

/// Points above this count trigger the import downsampling dialog.
public let downsamplePromptThreshold = 500

/// Default spacing between downsampled points, so longer tracks keep more points.
public let downsampleDefaultSpacingMeters = 15.0

/// Reduce a dense GPS track to at most `maxPoints` vertices.
///
/// The app renders one marker per route point, so importing a raw Strava
/// track (tens of thousands of fixes) can freeze the UI. We thin the track by
/// walking it and keeping a point only once we've moved at least `threshold`
/// away from the last kept point (the first and last points are always kept).
/// A short binary search picks the smallest threshold whose result still fits
/// within `maxPoints`, so the output lands as close to the target as possible.
public func downsamplePoints<T: CoordinateConvertible>(_ points: [T], maxPoints: Int) -> [T] {
    let n = points.count
    if n <= 2 || maxPoints < 2 || maxPoints >= n { return points }

    // Approximate distance using flat projection at the first point's latitude.
    let cosLat = cos(points[0].latitude * .pi / 180)
    func distance(_ a: T, _ b: T) -> Double {
        let dx = (b.longitude - a.longitude) * cosLat * 111320
        let dy = (b.latitude - a.latitude) * 110574
        return sqrt(dx * dx + dy * dy)
    }

    var totalLength = 0.0
    for i in 1..<n {
        totalLength += distance(points[i - 1], points[i])
    }

    if totalLength == 0 {
        let stride = Double(n - 1) / Double(maxPoints - 1)
        var even: [T] = []
        for i in 0..<(maxPoints - 1) {
            even.append(points[Int((Double(i) * stride).rounded())])
        }
        even.append(points[n - 1])
        return even
    }

    func decimate(_ threshold: Double) -> [T] {
        var kept: [T] = [points[0]]
        var last = points[0]
        for i in 1..<(n - 1) {
            if distance(last, points[i]) >= threshold {
                kept.append(points[i])
                last = points[i]
            }
        }
        kept.append(points[n - 1])
        return kept
    }

    var lo = 0.0
    var hi = totalLength
    var best = decimate(totalLength)
    for _ in 0..<24 {
        let mid = (lo + hi) / 2
        let candidate = decimate(mid)
        if candidate.count > maxPoints {
            lo = mid
        } else {
            hi = mid
            best = candidate
        }
    }
    return best
}

/// Protocol for types that have latitude/longitude, used by the downsampler.
public protocol CoordinateConvertible {
    var latitude: Double { get }
    var longitude: Double { get }
}

extension RoutePoint: CoordinateConvertible {
    public var latitude: Double { lat }
    public var longitude: Double { lon }
}

extension Coordinate: CoordinateConvertible {
    public var latitude: Double { lat }
    public var longitude: Double { lon }
}

/// Suggest a point budget that keeps roughly one point every `spacingMeters`.
public func defaultPointBudget(distanceMeters: Double, pointCount: Int, spacingMeters: Double = downsampleDefaultSpacingMeters) -> Int {
    guard distanceMeters.isFinite, distanceMeters > 0 else { return pointCount }
    return min(pointCount, max(2, Int(round(distanceMeters / spacingMeters))))
}