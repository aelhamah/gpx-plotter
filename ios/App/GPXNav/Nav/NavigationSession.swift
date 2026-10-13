import Foundation
import RouteKit

/// One navigation session: a route, the position along it, and whether the hiker
/// has wandered off it.
///
/// Deliberately a plain observable object with an explicit `ingest(_:)` rather
/// than something that subscribes to `CLLocationManager` itself. All the geometry
/// and the off-course rules live in RouteKit and are tested there
/// (`ProgressTests`); this is the wiring, and it is wired by the screen calling
/// `ingest` on each fix. That keeps the interesting behaviour testable without a
/// simulator and a location permission dialog.
///
/// The elevation provider is RouteKit's problem, not this type's: `RouteProgress`
/// resamples the route and fills the gaps from terrain, so grade ahead is a
/// lookup rather than a DEM call per tick.
@MainActor
final class NavigationSession: ObservableObject {
    /// What the nav screen shows, refreshed on every fix.
    struct Readout: Equatable {
        /// Metres left along the route.
        var remaining: Double
        /// Distance covered from the start.
        var covered: Double
        /// Progress 0...1.
        var fraction: Double
        /// Terrain elevation here, when the profile knows it.
        var elevation: Double?
        /// Grade over the lookahead window, percent. Positive is uphill.
        var gradeAhead: Double?
        /// Name of the next waypoint ahead, when there is one.
        var nextWaypoint: String?
        /// Metres from the route line.
        var offRoute: Double
    }

    @Published private(set) var readout: Readout?
    @Published private(set) var isOffCourse = false
    @Published private(set) var offCourseSince: Date?
    /// True once the hiker is within `arrivalThreshold` of the route's end.
    @Published private(set) var hasArrived = false
    @Published private(set) var startedAt: Date?

    /// Whether fixes keep arriving with the screen locked. False under when-in-use
    /// authorisation, and the screen says so rather than implying otherwise.
    var runsInBackground = false

    let route: Route
    /// Progress as 0...1, for the Live Activity bar in M4.
    var fractionComplete: Double { readout?.fraction ?? 0 }

    private var progress: RouteProgress
    private var detector = OffCourseDetector()
    private let arrivalThreshold: Double

    init(route: Route, waypoints: [Waypoint] = [], profile: RouteProfile? = nil) {
        self.route = route

        // Prefer a profile the caller already has — the viewer's `RouteAnalysis`
        // has one filled from terrain — so the nav readout and the profile chart
        // cannot disagree about how high the route is. Without it, resample the
        // route's own vertices, which is exact but only as good as the GPX.
        let resolved = profile ?? RouteProfile.make(from: route.points)
        progress = RouteProgress(
            route: route,
            waypoints: waypoints,
            stepMeters: RouteAnalysis.stepMeters,
            profile: resolved
        )

        // Close enough that the last fix — which is never exactly on the end point
        // — counts as having arrived. 30 m is about one GPS fix on a good day.
        arrivalThreshold = max(30, min(60, resolved.totalDistance * 0.01))
    }

    func start(at date: Date = Date()) {
        detector.start(at: date)
        startedAt = date
        isOffCourse = false
        offCourseSince = nil
        hasArrived = false
    }

    /// Fold one position fix into the session.
    ///
    /// - Parameters:
    ///   - fix: the position. Its `timestamp` drives every timing rule, so a batch
    ///     delivered late does not stretch the off-course window.
    ///   - speed: ground speed in m/s, used to ignore fixes taken while standing
    ///     still.
    func ingest(_ fix: LocationFix, speed: Double) {
        let state = progress.state(at: fix.coordinate)
        readout = Readout(
            remaining: state.remaining,
            covered: state.distanceAlong,
            fraction: state.fractionComplete,
            elevation: state.currentElevation,
            gradeAhead: state.gradeAheadPercent,
            nextWaypoint: state.nextWaypointName,
            offRoute: state.offCourseMeters
        )

        let offCourseState = detector.update(
            offCourseMeters: state.offCourseMeters,
            accuracyMeters: fix.accuracyMeters,
            speedMetersPerSecond: speed,
            at: fix.timestamp
        )
        switch offCourseState {
        case .offCourse(let since):
            if !isOffCourse { isOffCourse = true }
            offCourseSince = since
        case .onCourse, .idle:
            if isOffCourse { isOffCourse = false }
            offCourseSince = nil
        }

        if !hasArrived, state.remaining <= arrivalThreshold {
            hasArrived = true
        }
    }

    /// Elapsed time since `start`, for the timer on the nav screen.
    func elapsed(at date: Date = Date()) -> TimeInterval? {
        startedAt.map { date.timeIntervalSince($0) }
    }
}