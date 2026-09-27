import Foundation

/// A route sampled at a fixed ground spacing, with cumulative distances
/// precomputed once so every navigation tick is a binary search.
///
/// Built from `Profile.routeSamples(stepMeters:)`, so the distances along the
/// route match the elevation profile exactly. Interpolated samples carry no
/// elevation until the caller fills them from the DEM.
public struct RouteProfile: Equatable, Sendable {
    public let points: [RoutePoint]
    /// `cumulativeDistances[i]` is the distance from the start to `points[i]`.
    public let cumulativeDistances: [Double]
    public let totalDistance: Double

    public init(points: [RoutePoint], cumulativeDistances: [Double], totalDistance: Double) {
        self.points = points
        self.cumulativeDistances = cumulativeDistances
        self.totalDistance = totalDistance
    }

    /// Resample a route and accumulate distances along it.
    public static func make(from points: [RoutePoint], stepMeters: Double = 30) -> RouteProfile {
        let samples = Profile.routeSamples(points, stepMeters: stepMeters)
        var cumulative = [Double](repeating: 0, count: samples.count)
        for index in 1..<samples.count {
            cumulative[index] = cumulative[index - 1] + Haversine.meters(from: samples[index - 1], to: samples[index])
        }
        return RouteProfile(
            points: samples,
            cumulativeDistances: cumulative,
            totalDistance: cumulative.last ?? 0
        )
    }

    public var isEmpty: Bool { points.count < 2 }

    /// Index of the last sample at or before `distanceAlong`. Binary search —
    /// this is the hot path during navigation.
    public func index(atOrBefore distanceAlong: Double) -> Int {
        guard !cumulativeDistances.isEmpty else { return 0 }
        if distanceAlong <= 0 { return 0 }
        if distanceAlong >= totalDistance { return cumulativeDistances.count - 1 }

        var low = 0
        var high = cumulativeDistances.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if cumulativeDistances[mid] <= distanceAlong {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// Cumulative distance at a sample index.
    public func distance(at index: Int) -> Double {
        guard cumulativeDistances.indices.contains(index) else { return 0 }
        return cumulativeDistances[index]
    }

    /// Sample index nearest to a cumulative distance — the profile-trace
    /// selection, matching `nearestProfileSample` in the web app.
    public func index(nearestTo target: Double) -> Int {
        Profile.nearestSample(cumulative: cumulativeDistances, to: target)
    }

    /// Fill in the samples that resampling left without elevation.
    ///
    /// `Profile.routeSamples` only carries elevation on the original vertices, so
    /// a resampled profile is mostly `nil` until the caller supplies terrain
    /// elevations. Only the gaps are filled — vertex elevations are kept.
    public func fillingElevations(with provider: (Coordinate) -> Double?) -> RouteProfile {
        let filled = zip(points, cumulativeDistances).map { point, _ in
            guard point.elevation == nil else { return point }
            return RoutePoint(point.coordinate, elevation: provider(point.coordinate))
        }
        return RouteProfile(
            points: filled,
            cumulativeDistances: cumulativeDistances,
            totalDistance: totalDistance
        )
    }
}

/// What the nav bar shows for one location fix.
public struct RouteProgressState: Equatable, Sendable {
    /// Distance covered from the start of the route.
    public var distanceAlong: Double
    /// Distance still to walk.
    public var remaining: Double
    /// Progress as 0...1, for the Live Activity bar.
    public var fractionComplete: Double
    /// Interpolated elevation at the current position, when the profile has one.
    public var currentElevation: Double?
    /// Grade over the lookahead window, as a percentage (100 = +100%).
    public var gradeAheadPercent: Double?
    /// Name of the next waypoint ahead, if any.
    public var nextWaypointName: String?
    /// Metres from the route line. Zero when following it.
    public var offCourseMeters: Double

    public init(
        distanceAlong: Double,
        remaining: Double,
        fractionComplete: Double,
        currentElevation: Double?,
        gradeAheadPercent: Double?,
        nextWaypointName: String?,
        offCourseMeters: Double
    ) {
        self.distanceAlong = distanceAlong
        self.remaining = remaining
        self.fractionComplete = fractionComplete
        self.currentElevation = currentElevation
        self.gradeAheadPercent = gradeAheadPercent
        self.nextWaypointName = nextWaypointName
        self.offCourseMeters = offCourseMeters
    }
}

/// Trail-following progress. Pure geometry: no DEM calls and no network per
/// tick, because the profile is precomputed when navigation starts.
public struct RouteProgress: Sendable {
    /// How far ahead the grade is averaged over, per the plan.
    public static let gradeLookaheadMeters: Double = 200
    /// How far off the route a fix may be and still be matched to it. Wide
    /// enough that `offCourseMeters` reports the real lateral distance instead
    /// of saturating at the search limit.
    public static let projectionRadiusMeters: Double = 2_000

    public let profile: RouteProfile
    private let waypoints: [Waypoint]
    private let routeCoordinates: [Coordinate]
    /// Cumulative distance at each *route vertex*, parallel to `routeCoordinates`.
    /// Needed because `profile` is resampled to a different length.
    private let vertexDistances: [Double]

    /// - Parameters:
    ///   - route: the route being followed.
    ///   - waypoints: markers to report as "next".
    ///   - stepMeters: resample spacing for the elevation profile.
    ///   - elevationProvider: fills in the samples that `Profile.routeSamples`
    ///     leaves without elevation. The plan has the caller supply DEM
    ///     elevations here; without it, grade is simply unavailable.
    public init(
        route: Route,
        waypoints: [Waypoint] = [],
        stepMeters: Double = 30,
        elevationProvider: ((Coordinate) -> Double?)? = nil
    ) {
        var profile = RouteProfile.make(from: route.points, stepMeters: stepMeters)
        if let elevationProvider {
            profile = profile.fillingElevations(with: elevationProvider)
        }
        self.profile = profile
        self.waypoints = waypoints
        self.routeCoordinates = route.points.map(\.coordinate)

        var distances = [Double](repeating: 0, count: route.points.count)
        for index in 1..<max(route.points.count, 1) where !route.points.isEmpty {
            distances[index] = distances[index - 1]
                + Haversine.meters(from: route.points[index - 1], to: route.points[index])
        }
        self.vertexDistances = distances
    }

    /// Project a fix onto the route and describe the hiker's state.
    ///
    /// `distanceAlong` comes from the nearest point on the *drawn* polyline
    /// (so it stays consistent with what the map shows), while elevation and
    /// grade come from the resampled profile.
    public func state(at fix: Coordinate) -> RouteProgressState {
        let snap = nearestOnLine(fix, routeCoordinates, Self.projectionRadiusMeters)
        let along = snap.map { self.distanceAlong(for: $0) } ?? 0
        let clamped = min(max(along, 0), profile.totalDistance)

        let index = profile.index(atOrBefore: clamped)
        let nextIndex = min(index + 1, profile.points.count - 1)

        let fraction: Double = profile.totalDistance > 0 ? clamped / profile.totalDistance : 0
        return RouteProgressState(
            distanceAlong: clamped,
            remaining: max(0, profile.totalDistance - clamped),
            fractionComplete: min(max(fraction, 0), 1),
            currentElevation: Self.interpolatedElevation(in: profile, at: clamped, index: index, nextIndex: nextIndex),
            gradeAheadPercent: gradeAhead(from: clamped, index: index),
            nextWaypointName: nextWaypoint(after: clamped)?.name,
            offCourseMeters: snap?.distanceMeters ?? Self.projectionRadiusMeters
        )
    }

    // MARK: - Distance along

    /// Walk the matched segment to get the distance along the route, then add
    /// the cumulative distance at that segment's start.
    private func distanceAlong(for result: SnapResult) -> Double {
        guard let segment = result.segment else {
            // Single-point line: nothing to interpolate along.
            return 0
        }
        let startIndex = nearestVertexIndex(to: segment.a)
        let base = vertexDistances.indices.contains(startIndex) ? vertexDistances[startIndex] : 0
        let segmentLength = Haversine.meters(from: segment.a, to: segment.b)
        return min(base + segmentLength * segment.t, profile.totalDistance)
    }

    /// Index of the route vertex nearest a point on the route line.
    private func nearestVertexIndex(to target: Coordinate) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for (index, coordinate) in routeCoordinates.enumerated() {
            let distance = Haversine.meters(from: coordinate, to: target)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    // MARK: - Elevation and grade

    private static func interpolatedElevation(
        in profile: RouteProfile,
        at distance: Double,
        index: Int,
        nextIndex: Int
    ) -> Double? {
        let here = profile.points[index].elevation
        let next = profile.points[nextIndex].elevation
        guard let here, let next, nextIndex > index else { return here }

        let span = profile.cumulativeDistances[nextIndex] - profile.cumulativeDistances[index]
        guard span > 0 else { return here }
        let t = (distance - profile.cumulativeDistances[index]) / span
        return here + (next - here) * t
    }

    /// Average grade over the next `gradeLookaheadMeters`, in percent.
    private func gradeAhead(from distance: Double, index: Int) -> Double? {
        let lookahead = min(Self.gradeLookaheadMeters, profile.totalDistance - distance)
        guard lookahead > 0 else { return nil }

        let endIndex = profile.index(atOrBefore: distance + lookahead)
        let startElevation = profile.points[index].elevation
        let endElevation = profile.points[endIndex].elevation
        guard let startElevation, let endElevation else { return nil }

        let rise = endElevation - startElevation
        return (rise / lookahead) * 100
    }

    // MARK: - Waypoints

    /// Nearest waypoint ahead of `distance`, using each waypoint's position along
    /// the route. Falls back to the first waypoint when none lies ahead.
    private func nextWaypoint(after distance: Double) -> Waypoint? {
        let alongRoute = waypoints.map { waypoint -> (Waypoint, Double) in
            let snap = nearestOnLine(waypoint.coordinate, routeCoordinates, Self.projectionRadiusMeters)
            let along = snap.map { self.distanceAlong(for: $0) } ?? 0
            return (waypoint, along)
        }

        let ahead = alongRoute
            .filter { $0.1 > distance }
            .sorted { $0.1 < $1.1 }

        return ahead.first?.0 ?? waypoints.first
    }
}
