import XCTest
@testable import RouteKit

/// Port of `web/tests/snap.test.ts` — the geometry and copy the draw flow
/// depends on. `nearestOnLine` itself is already exercised through
/// `ProgressTests`; this suite covers the multi-line helpers, the radii, and
/// the draw-bar copy.
final class SnapGeometryTests: XCTestCase {
    // MARK: - flatDistanceMeters

    func testIsAbout111Point3KmPerLongitudeDegreeAtTheEquator() {
        let d = flatDistanceMeters(Coordinate(lat: 0, lon: 0), Coordinate(lat: 0, lon: 0.001))
        XCTAssertGreaterThan(d, 100)
        XCTAssertLessThan(d, 130)
    }

    func testIsAbout110Point6KmPerLatitudeDegree() {
        let d = flatDistanceMeters(Coordinate(lat: 0, lon: 0), Coordinate(lat: 0.001, lon: 0))
        XCTAssertGreaterThan(d, 100)
        XCTAssertLessThan(d, 120)
    }

    func testShrinksAlongLongitudesAsLatitudeRises() {
        let equator = flatDistanceMeters(Coordinate(lat: 0, lon: 0), Coordinate(lat: 0, lon: 0.001))
        let high = flatDistanceMeters(Coordinate(lat: 45, lon: 0), Coordinate(lat: 45, lon: 0.001))
        XCTAssertLessThan(high, equator)
    }

    // MARK: - projectToSegment

    func testProjectsOntoTheInteriorOfTheSegment() {
        let point = projectToSegment(
            Coordinate(lat: 0.0001, lon: 0.0002),
            Coordinate(lat: 0, lon: 0),
            Coordinate(lat: 0, lon: 0.0004)
        )
        XCTAssertEqual(point.lon, 0.0002, accuracy: 1e-9)
        XCTAssertEqual(point.lat, 0, accuracy: 1e-9)
    }

    func testClampsToTheSegmentStartBeyondPointA() {
        let point = projectToSegment(
            Coordinate(lat: 0.0001, lon: -0.0001),
            Coordinate(lat: 0, lon: 0),
            Coordinate(lat: 0, lon: 0.0004)
        )
        XCTAssertEqual(point.lon, 0, accuracy: 1e-9)
    }

    func testClampsToTheSegmentEndBeyondPointB() {
        let point = projectToSegment(
            Coordinate(lat: 0, lon: 0.0007),
            Coordinate(lat: 0, lon: 0),
            Coordinate(lat: 0, lon: 0.0004)
        )
        XCTAssertEqual(point.lon, 0.0004, accuracy: 1e-9)
    }

    // MARK: - nearestOnLine

    func testSnapsToThePointOfASinglePointLineWithinRange() {
        let peak = Coordinate(lat: 39, lon: -105)
        let hit = nearestOnLine(Coordinate(lat: 39.001, lon: -105), [peak], PEAK_SNAP_METERS)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.point, peak)
        XCTAssertEqual(hit?.distanceMeters ?? 0, 110.6, accuracy: 1)
    }

    func testReturnsNilBeyondTheMaxDistanceForASinglePoint() {
        let peak = Coordinate(lat: 39, lon: -105)
        XCTAssertNil(nearestOnLine(Coordinate(lat: 39.01, lon: -105), [peak], PEAK_SNAP_METERS))
    }

    func testReturnsNilForAnEmptyLine() {
        XCTAssertNil(nearestOnLine(Coordinate(lat: 0, lon: 0), [], TRAIL_SNAP_METERS))
    }

    // MARK: - nearestSnap

    let trail = [Coordinate(lat: 39, lon: -105), Coordinate(lat: 39, lon: -104.99)]
    let other = [Coordinate(lat: 39.02, lon: -105), Coordinate(lat: 39.02, lon: -104.99)]

    func testPicksTheClosestOfSeveralLines() {
        // Point is far closer to `trail` (~0 dist) than to `other` (~2.2 km).
        let hit = nearestSnap(Coordinate(lat: 39.0001, lon: -105), [trail, other], 100)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.point.lon ?? 0, -105, accuracy: 1e-6)
        XCTAssertEqual(hit?.point.lat ?? 0, 39, accuracy: 1e-6)
    }

    func testRejectsAllLinesBeyondTheThreshold() {
        XCTAssertNil(nearestSnap(Coordinate(lat: 39.05, lon: -105), [trail, other], 100))
    }

    func testSnapsAPointNearASlopedTrailOntoTheTrailLine() {
        let sloped = [Coordinate(lat: 39, lon: -105), Coordinate(lat: 39.001, lon: -104.99)]
        let hit = nearestSnap(Coordinate(lat: 39.0004, lon: -104.995), [sloped], TRAIL_SNAP_METERS)
        XCTAssertNotNil(hit)
        XCTAssertLessThan(hit?.distanceMeters ?? .infinity, TRAIL_SNAP_METERS)
    }

    // MARK: - nearestLine

    func testReturnsTheMatchedLineAndTheProjectedSegment() {
        let hit = nearestLine(Coordinate(lat: 39.0002, lon: -104.995), [trail], TRAIL_SNAP_METERS)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.line, trail)
        XCTAssertNotNil(hit?.result.segment)
        XCTAssertEqual(hit?.result.segment?.t ?? 0, 0.5, accuracy: 0.1)
        XCTAssertEqual(hit?.result.segment?.a, trail[0])
        XCTAssertEqual(hit?.result.segment?.b, trail[1])
    }

    func testHasNoSegmentForASinglePointLine() {
        let peak = [Coordinate(lat: 39, lon: -105)]
        let hit = nearestLine(Coordinate(lat: 39.0005, lon: -105), [peak], PEAK_SNAP_METERS)
        XCTAssertNotNil(hit)
        XCTAssertNil(hit?.result.segment)
    }

    func testReachesFurtherForAPeakThanForATrail() {
        // Peaks are sparse landmarks a user taps near deliberately; a trail
        // has to be under the finger, so a much wider reach there would grab
        // the wrong one.
        XCTAssertGreaterThan(PEAK_SNAP_METERS, TRAIL_SNAP_METERS)
    }

    // MARK: - Draw-bar copy

    func testDrawStatusMentionsSnappingWhileTheRouteIsStillEmpty() {
        XCTAssertTrue(drawStatusText(pointCount: 0, snappingEnabled: true).contains("snaps to trails"))
        XCTAssertTrue(drawStatusText(pointCount: 1, snappingEnabled: true).contains("snaps to trails"))
    }

    func testDrawStatusDropsTheSnappingClauseWhenSnappingIsOff() {
        XCTAssertFalse(drawStatusText(pointCount: 0, snappingEnabled: false).contains("snaps to trails"))
        XCTAssertTrue(drawStatusText(pointCount: 0, snappingEnabled: false).contains("Tap the map to add points"))
    }

    func testDrawStatusDropsTheClauseOnceTheRouteCanBeFinished() {
        // The clause is about the next tap, and there is no next tap to place.
        XCTAssertEqual(
            drawStatusText(pointCount: 2, snappingEnabled: true),
            drawStatusText(pointCount: 2, snappingEnabled: false)
        )
    }

    func testWaypointHintMentionsPeaksOnlyWhileSnappingIsOn() {
        XCTAssertTrue(waypointHintText(snappingEnabled: true).contains("snaps to peaks"))
        XCTAssertFalse(waypointHintText(snappingEnabled: false).contains("snaps to peaks"))
        XCTAssertTrue(waypointHintText(snappingEnabled: false).contains("Tap to place a waypoint"))
    }

    func testSnapIsEnabledByDefault() {
        XCTAssertTrue(SNAP_ENABLED_BY_DEFAULT)
    }
}
