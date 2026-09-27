import XCTest
@testable import RouteKit

/// Covers `RouteProfile` / `RouteProgress` (docs/ios-plan.md §7) and
/// `OffCourseDetector`'s thresholds.
final class ProgressTests: XCTestCase {
    private func sampleRoute() -> Route {
        // A ~2.2 km east-west route along the equator, 1 km apart.
        Route(
            id: 1,
            name: "Test",
            points: [
                RoutePoint(lat: 0, lon: 0, elevation: 1000),
                RoutePoint(lat: 0, lon: 0.25, elevation: 1100),
                RoutePoint(lat: 0, lon: 0.50, elevation: 1050),
                RoutePoint(lat: 0, lon: 0.75, elevation: 1200),
                RoutePoint(lat: 0, lon: 1.00, elevation: 1150),
            ],
            color: "#e11d48"
        )
    }

    // MARK: - RouteProfile

    func testProfileCumulativeDistancesAreMonotonicAndEndAtTotal() {
        let profile = RouteProfile.make(from: sampleRoute().points, stepMeters: 30)
        XCTAssertGreaterThan(profile.totalDistance, 100_000)
        XCTAssertEqual(profile.points.count, profile.cumulativeDistances.count)
        XCTAssertEqual(profile.cumulativeDistances.first, 0)
        XCTAssertEqual(profile.cumulativeDistances.last ?? 0, profile.totalDistance, accuracy: 1e-6)
        for index in 1..<profile.cumulativeDistances.count {
            XCTAssertGreaterThanOrEqual(profile.cumulativeDistances[index], profile.cumulativeDistances[index - 1])
        }
    }

    func testProfileIndexBinarySearchMatchesLinearScan() {
        let profile = RouteProfile.make(from: sampleRoute().points, stepMeters: 30)
        for target in stride(from: 0.0, through: profile.totalDistance, by: 997) {
            let found = profile.index(atOrBefore: target)
            XCTAssertLessThanOrEqual(profile.distance(at: found), target + 1e-6)
            if found + 1 < profile.cumulativeDistances.count {
                XCTAssertGreaterThan(profile.distance(at: found + 1), target)
            }
        }
    }

    func testProfileIndexClampsToEnds() {
        let profile = RouteProfile.make(from: sampleRoute().points, stepMeters: 30)
        XCTAssertEqual(profile.index(atOrBefore: -500), 0)
        XCTAssertEqual(profile.index(atOrBefore: .greatestFiniteMagnitude), profile.points.count - 1)
    }

    // MARK: - RouteProgress

    func testProgressAtStartAndEnd() {
        let progress = RouteProgress(route: sampleRoute())
        let start = progress.state(at: Coordinate(lat: 0, lon: 0))
        XCTAssertEqual(start.distanceAlong, 0, accuracy: 1)
        XCTAssertEqual(start.fractionComplete, 0, accuracy: 0.01)
        XCTAssertEqual(start.offCourseMeters, 0, accuracy: 1)
        XCTAssertEqual(start.remaining ?? 0, progress.profile.totalDistance, accuracy: 1)

        let end = progress.state(at: Coordinate(lat: 0, lon: 1.0))
        XCTAssertEqual(end.fractionComplete, 1, accuracy: 0.01)
        XCTAssertEqual(end.remaining ?? -1, 0, accuracy: 1)
    }

    func testProgressIncreasesAlongTheRoute() {
        let progress = RouteProgress(route: sampleRoute())
        let halfway = progress.state(at: Coordinate(lat: 0, lon: 0.5))
        XCTAssertEqual(halfway.fractionComplete, 0.5, accuracy: 0.05)
        XCTAssertEqual(halfway.distanceAlong, progress.profile.totalDistance / 2, accuracy: 2000)
    }

    func testProgressReportsOffCourseDistance() {
        let progress = RouteProgress(route: sampleRoute())
        // ~1.1 km north of the route at the equator.
        let offRoute = progress.state(at: Coordinate(lat: 0.01, lon: 0.5))
        XCTAssertEqual(offRoute.offCourseMeters, 1113, accuracy: 60)
    }

    func testProgressGradeIsPositiveGoingUphill() {
        // `routeSamples` leaves interior samples without elevation, so the
        // profile is DEM-filled the way the app fills it.
        let progress = RouteProgress(
            route: sampleRoute(),
            elevationProvider: Self.linearElevation(through: sampleRoute().points)
        )
        let state = progress.state(at: Coordinate(lat: 0, lon: 0.01))
        XCTAssertNotNil(state.gradeAheadPercent)
        XCTAssertGreaterThan(state.gradeAheadPercent ?? 0, 0)
    }

    func testProgressGradeIsNegativeGoingDownhill() {
        // The same route walked backwards from the summit descends.
        let progress = RouteProgress(
            route: sampleRoute(),
            elevationProvider: Self.linearElevation(through: sampleRoute().points)
        )
        let state = progress.state(at: Coordinate(lat: 0, lon: 0.99))
        XCTAssertLessThan(state.gradeAheadPercent ?? 0, 0)
    }

    func testProgressGradeIsNilWithoutElevations() {
        let progress = RouteProgress(route: sampleRoute())
        let state = progress.state(at: Coordinate(lat: 0, lon: 0.5))
        XCTAssertNil(state.gradeAheadPercent)
    }

    /// Stands in for the DEM: linear interpolation between route vertices.
    private static func linearElevation(through points: [RoutePoint]) -> (Coordinate) -> Double? {
        { coordinate in
            for index in 1..<points.count {
                let a = points[index - 1]
                let b = points[index]
                let low = min(a.lon, b.lon)
                let high = max(a.lon, b.lon)
                guard coordinate.lon >= low, coordinate.lon <= high else { continue }
                let span = b.lon - a.lon
                let t = span == 0 ? 0 : (coordinate.lon - a.lon) / span
                guard let aElevation = a.elevation, let bElevation = b.elevation else { return nil }
                return aElevation + (bElevation - aElevation) * t
            }
            return nil
        }
    }

    func testProgressFindsNextWaypointAhead() {
        let route = sampleRoute()
        let near = Waypoint(lat: 0, lon: 0.1, name: "Near")
        let far = Waypoint(lat: 0, lon: 0.9, name: "Far")
        let progress = RouteProgress(route: route, waypoints: [far, near])

        let state = progress.state(at: Coordinate(lat: 0, lon: 0.05))
        XCTAssertEqual(state.nextWaypointName, "Near")
    }

    func testProgressHandlesSinglePointRoute() {
        let progress = RouteProgress(route: Route(id: 1, name: "Dot", points: [RoutePoint(lat: 0, lon: 0)], color: "#fff"))
        let state = progress.state(at: Coordinate(lat: 0, lon: 0))
        XCTAssertEqual(state.distanceAlong, 0)
        XCTAssertEqual(state.fractionComplete, 0)
    }

    // MARK: - OffCourseDetector

    private func startedDetector() -> OffCourseDetector {
        var detector = OffCourseDetector()
        detector.start(at: Date(timeIntervalSince1970: 1_000))
        return detector
    }

    func testDetectorStaysOnCourseNearTheRoute() {
        var detector = startedDetector()
        let state = detector.update(
            offCourseMeters: 5, accuracyMeters: 10, speedMetersPerSecond: 1.4,
            at: Date(timeIntervalSince1970: 1_020)
        )
        XCTAssertEqual(state, .onCourse)
        XCTAssertFalse(detector.isOffCourse)
    }

    func testDetectorIgnoresTheSettlingWindow() {
        var detector = startedDetector()
        // 10 s in, well past the threshold but inside the 15 s settling window.
        let state = detector.update(
            offCourseMeters: 200, accuracyMeters: 5, speedMetersPerSecond: 1.4,
            at: Date(timeIntervalSince1970: 1_010)
        )
        XCTAssertEqual(state, .onCourse)
    }

    func testDetectorEntersOffCourseAfterSustainedDeviation() {
        var detector = startedDetector()
        let start = Date(timeIntervalSince1970: 2_000)

        // Deviating, but not yet for 8 s.
        var state = detector.update(offCourseMeters: 60, accuracyMeters: 5, speedMetersPerSecond: 1.4, at: start)
        XCTAssertEqual(state, .onCourse)
        state = detector.update(
            offCourseMeters: 60, accuracyMeters: 5, speedMetersPerSecond: 1.4,
            at: start.addingTimeInterval(7)
        )
        XCTAssertEqual(state, .onCourse, "7 s is short of the 8 s threshold")

        state = detector.update(
            offCourseMeters: 60, accuracyMeters: 5, speedMetersPerSecond: 1.4,
            at: start.addingTimeInterval(8)
        )
        XCTAssertEqual(state, .offCourse(since: start.addingTimeInterval(8)))
    }

    func testDetectorResetsTheTimerWhenDeviationStops() {
        var detector = startedDetector()
        let start = Date(timeIntervalSince1970: 3_000)

        _ = detector.update(offCourseMeters: 60, accuracyMeters: 5, speedMetersPerSecond: 1.4, at: start)
        _ = detector.update(
            offCourseMeters: 60, accuracyMeters: 5, speedMetersPerSecond: 1.4,
            at: start.addingTimeInterval(7)
        )
        // Back on route, so the sustained-deviation timer must reset.
        _ = detector.update(
            offCourseMeters: 2, accuracyMeters: 5, speedMetersPerSecond: 1.4,
            at: start.addingTimeInterval(7.5)
        )
        // Deviating again for 7 s from a fresh start is still not enough.
        let state = detector.update(
            offCourseMeters: 60, accuracyMeters: 5, speedMetersPerSecond: 1.4,
            at: start.addingTimeInterval(14.5)
        )
        XCTAssertEqual(state, .onCourse)
    }

    func testDetectorClearsOnlyAfterSustainedRecovery() {
        var detector = startedDetector()
        let start = Date(timeIntervalSince1970: 4_000)

        _ = detector.update(offCourseMeters: 100, accuracyMeters: 5, speedMetersPerSecond: 1.4, at: start)
        var state = detector.update(
            offCourseMeters: 100, accuracyMeters: 5, speedMetersPerSecond: 1.4,
            at: start.addingTimeInterval(8)
        )
        XCTAssertTrue(detector.isOffCourse)

        // In the hysteresis band (25...40 m): neither clears nor re-alerts.
        for offset in [9.0, 11.0, 20.0] {
            state = detector.update(
                offCourseMeters: 30, accuracyMeters: 5, speedMetersPerSecond: 1.4,
                at: start.addingTimeInterval(offset)
            )
            XCTAssertTrue(detector.isOffCourse, "still off course at t+\(offset)")
        }

        // Close to the route, but not for the full 5 s yet. The band updates
        // above keep resetting the recovery timer, so it starts at t+24.
        state = detector.update(
            offCourseMeters: 5, accuracyMeters: 5, speedMetersPerSecond: 1.4,
            at: start.addingTimeInterval(24)
        )
        XCTAssertTrue(detector.isOffCourse, "recovery just started")
        state = detector.update(
            offCourseMeters: 5, accuracyMeters: 5, speedMetersPerSecond: 1.4,
            at: start.addingTimeInterval(28.9)
        )
        XCTAssertTrue(detector.isOffCourse, "4.9 s of recovery is short of 5 s")
        state = detector.update(
            offCourseMeters: 5, accuracyMeters: 5, speedMetersPerSecond: 1.4,
            at: start.addingTimeInterval(29)
        )
        XCTAssertEqual(state, .onCourse)
        XCTAssertFalse(detector.isOffCourse)
    }

    func testDetectorIgnoresBadAccuracyAndStandingStill() {
        var detector = startedDetector()
        let start = Date(timeIntervalSince1970: 5_000)

        // Poor accuracy, sustained well past the threshold.
        var state = detector.update(offCourseMeters: 300, accuracyMeters: 50, speedMetersPerSecond: 1.4, at: start)
        for offset in [1.0, 5.0, 30.0] {
            state = detector.update(
                offCourseMeters: 300, accuracyMeters: 50, speedMetersPerSecond: 1.4,
                at: start.addingTimeInterval(offset)
            )
        }
        XCTAssertEqual(state, .onCourse, "accuracy gate suppresses the alert")

        // Good accuracy but not moving — standing-start GPS wander.
        state = detector.update(offCourseMeters: 300, accuracyMeters: 5, speedMetersPerSecond: 0.1, at: start)
        for offset in [1.0, 5.0, 30.0] {
            state = detector.update(
                offCourseMeters: 300, accuracyMeters: 5, speedMetersPerSecond: 0.1,
                at: start.addingTimeInterval(offset)
            )
        }
        XCTAssertEqual(state, .onCourse, "speed gate suppresses the alert")
    }

    func testDetectorResetReturnsToIdle() {
        var detector = startedDetector()
        _ = detector.update(offCourseMeters: 100, accuracyMeters: 5, speedMetersPerSecond: 1.4, at: Date())
        detector.reset()
        XCTAssertEqual(detector.state, .idle)
        XCTAssertFalse(detector.isOffCourse)
    }
}
