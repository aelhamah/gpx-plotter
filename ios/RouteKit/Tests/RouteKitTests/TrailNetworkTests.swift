import XCTest
@testable import RouteKit

/// Port of `web/tests/trailGraph.test.ts`.
final class TrailNetworkTests: XCTestCase {
    /// `[lon, lat]` pairs → coordinates, the web suite's `line` helper.
    func line(_ points: (Double, Double)...) -> [Coordinate] {
        points.map { Coordinate(lat: $0.1, lon: $0.0) }
    }

    // MARK: - dedupeTrailLines

    func testDropsIdenticalPolylinesButKeepsDistinctOnes() {
        let a = line((0, 0), (0.001, 0))
        let same = line((0, 0), (0.001, 0))
        let other = line((0, 0), (0, 0.001))
        XCTAssertEqual(TrailNetwork.dedupeTrailLines([a, same, other]), [a, other])
    }

    func testDropsDegenerateSinglePointLines() {
        XCTAssertEqual(TrailNetwork.dedupeTrailLines([line((0, 0)), line((0, 0), (0.001, 0))]).count, 1)
    }

    // MARK: - routeAlongTrails

    func testRoutesAlongAConnectedTrailThroughItsVertices() {
        let trails = [line((0, 0), (0.001, 0), (0.001, 0.001))]
        let path = TrailNetwork.routeAlongTrails(trails, start: Coordinate(lat: 0, lon: 0), end: Coordinate(lat: 0.001, lon: 0.001))
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.count, 3)
        XCTAssertEqual(path?[1].lon ?? 0, 0.001, accuracy: 1e-6)
        XCTAssertEqual(path?[1].lat ?? 0, 0, accuracy: 1e-6)
    }

    func testBridgesASplitWayWhoseLooseEndsAreWithinTheJoinDistance() {
        let gap = TrailNetwork.joinMeters / 2 / 110_574 // half the join distance in degrees latitude
        let first = line((0, 0), (0, 0.001))
        let second = line((0, 0.001 + gap), (0, 0.002))
        let path = TrailNetwork.routeAlongTrails(
            [first, second],
            start: Coordinate(lat: 0, lon: 0),
            end: Coordinate(lat: 0.002, lon: 0)
        )
        XCTAssertNotNil(path)
        XCTAssertGreaterThanOrEqual(path?.count ?? 0, 4)
    }

    func testDoesNotBridgeLooseEndsBeyondTheJoinDistance() {
        let gap = TrailNetwork.joinMeters * 5 / 110_574
        let first = line((0, 0), (0, 0.001))
        let second = line((0, 0.001 + gap), (0, 0.002))
        let path = TrailNetwork.routeAlongTrails(
            [first, second],
            start: Coordinate(lat: 0, lon: 0),
            end: Coordinate(lat: 0.002, lon: 0)
        )
        XCTAssertNil(path)
    }

    func testRejectsAPathWhoseDetourExceedsTheLimit() {
        // Two parallel trails whose far ends connect (~11 m apart), but whose
        // near ends are only ~11 m apart yet not directly linked: the network
        // path is ~2 km, so the detour guard must refuse it.
        let trails = [
            line((-0.01, 0), (0, 0), (0.01, 0)),
            line((-0.01, 0.0001), (0, 0.0001), (0.01, 0.0001)),
        ]
        let path = TrailNetwork.routeAlongTrails(
            trails,
            start: Coordinate(lat: 0, lon: 0),
            end: Coordinate(lat: 0.0001, lon: 0)
        )
        XCTAssertNil(path)
    }

    func testReturnsNilWithNoTrailsAtAll() {
        let path = TrailNetwork.routeAlongTrails(
            [],
            start: Coordinate(lat: 0, lon: 0),
            end: Coordinate(lat: 0, lon: 0.001)
        )
        XCTAssertNil(path)
    }

    // MARK: - trailVerticesBetween

    func testSplicesTheInteriorVerticesOfATrail() {
        let trail = line((0, 0), (0.001, 0), (0.002, 0), (0.003, 0))
        let interior = TrailNetwork.trailVerticesBetween(
            [trail],
            from: Coordinate(lat: 0, lon: 0),
            to: Coordinate(lat: 0, lon: 0.003),
            radiusMeters: TRAIL_SNAP_METERS
        )
        // Both endpoints excluded; the two interior vertices remain.
        XCTAssertEqual(interior.count, 2)
        XCTAssertEqual(interior.first?.lon ?? 0, 0.001, accuracy: 1e-6)
        XCTAssertEqual(interior.last?.lon ?? 0, 0.002, accuracy: 1e-6)
    }

    func testReturnsNothingWhenTheFromPointIsOffTheNetwork() {
        let trail = line((0, 0), (0.001, 0))
        let interior = TrailNetwork.trailVerticesBetween(
            [trail],
            from: Coordinate(lat: 0.01, lon: 0.01), // ~1 km away
            to: Coordinate(lat: 0, lon: 0.001),
            radiusMeters: TRAIL_SNAP_METERS
        )
        XCTAssertTrue(interior.isEmpty)
    }
}
