import XCTest
@testable import RouteKit

final class MapFitTests: XCTestCase {
    /// A whole-degree box on a 390×700 viewport: the span is 1/360 of the world
    /// wide, so at zoom `z` one world point is 512×2^z points and the box is
    /// (1/360)×512×2^z points across.

    private func bounds(
        west: Double = 0, south: Double = 0, east: Double = 1, north: Double = 1
    ) -> (west: Double, south: Double, east: Double, north: Double) {
        (west, south, east, north)
    }

    func testFitsTheNarrowerAxis() {
        // A wide, short box is limited by its height, not its width.
        let wide = MapFit.zoom(
            bounds: bounds(west: -10, south: 45, east: 10, north: 46),
            viewport: (width: 800, height: 400)
        )
        let tall = MapFit.zoom(
            bounds: bounds(west: -10, south: 40, east: 10, north: 50),
            viewport: (width: 800, height: 400)
        )
        XCTAssertNotNil(wide)
        XCTAssertNotNil(tall)
        // More latitude means a bigger vertical span, so the tall box needs to be
        // zoomed out further to fit the same viewport.
        XCTAssertLessThan(tall!, wide!)
    }

    func testPaddingForcesAFurtherZoomOut() {
        let box = bounds(west: -0.1, south: 37, east: 0.1, north: 38)
        let viewport = (width: 400.0, height: 800.0)
        let flush = MapFit.zoom(bounds: box, viewport: viewport)!
        let padded = MapFit.zoom(
            bounds: box,
            viewport: viewport,
            padding: (top: 120, left: 40, bottom: 120, right: 40)
        )!
        XCTAssertLessThan(padded, flush)
    }

    /// The case from the bug report: a four-block loop in San Francisco fitted to
    /// a phone. It wants z17, which is past everything `outdoor-v2` serves.
    func testASmallUrbanRouteAsksForTooMuch() {
        let cityBlockLoop = MapFit.zoom(
            bounds: bounds(west: -122.41905, south: 37.75755, east: -122.41595, north: 37.75993),
            viewport: (width: 402, height: 874),
            padding: (top: 60, left: 40, bottom: 60, right: 40)
        )
        XCTAssertNotNil(cityBlockLoop)
        XCTAssertGreaterThan(cityBlockLoop!, 15, "A city block should want to zoom past z15")
    }

    /// ...and clamping is what keeps that from becoming a blank basemap.
    func testClampingPullsItBackInsideTheTileset() {
        let clamped = MapFit.clampedZoom(
            bounds: bounds(west: -122.41905, south: 37.75755, east: -122.41595, north: 37.75993),
            viewport: (width: 402, height: 874),
            padding: (top: 60, left: 40, bottom: 60, right: 40),
            maxZoom: 15
        )
        XCTAssertEqual(clamped!, 15)
    }

    func testClampingLeavesARouteThatAlreadyFitsAlone() {
        let loose = MapFit.clampedZoom(
            bounds: bounds(west: -106.5, south: 39.0, east: -106.4, north: 39.1),
            viewport: (width: 402, height: 874),
            maxZoom: 15
        )
        let raw = MapFit.zoom(
            bounds: bounds(west: -106.5, south: 39.0, east: -106.4, north: 39.1),
            viewport: (width: 402, height: 874)
        )
        XCTAssertEqual(loose!, raw!)
    }

    func testDegenerateBoxesHaveNoZoom() {
        // A route that is a single point, or a straight vertical line.
        XCTAssertNil(MapFit.zoom(bounds: bounds(west: 1, south: 2, east: 1, north: 2), viewport: (width: 400, height: 400)))
        XCTAssertNil(MapFit.zoom(bounds: bounds(west: 1, south: 2, east: 1, north: 3), viewport: (width: 400, height: 400)))
        XCTAssertNil(MapFit.zoom(bounds: bounds(west: 1, south: 2, east: 2, north: 2), viewport: (width: 400, height: 400)))
    }

    /// Padding larger than the viewport is a caller bug, not a route shape, and
    /// must not produce a zoom of negative infinity.
    func testPaddingLargerThanTheViewportIsRejected() {
        XCTAssertNil(MapFit.zoom(
            bounds: bounds(),
            viewport: (width: 100, height: 100),
            padding: (top: 80, left: 80, bottom: 80, right: 80)
        ))
    }

    func testMercatorYIsZeroAtTheNorthEdge() {
        XCTAssertEqual(MapFit.mercatorY(MapFit.latitudeLimit), 0, accuracy: 1e-9)
        XCTAssertEqual(MapFit.mercatorY(-MapFit.latitudeLimit), 1, accuracy: 1e-9)
        XCTAssertEqual(MapFit.mercatorY(0), 0.5, accuracy: 1e-9)
    }

    /// Latitudes past the Mercator limit have to clamp, not blow up.
    func testMercatorYClampsBeyondThePoles() {
        XCTAssertEqual(MapFit.mercatorY(89), MapFit.mercatorY(MapFit.latitudeLimit), accuracy: 1e-9)
        XCTAssertEqual(MapFit.mercatorY(-89), MapFit.mercatorY(-MapFit.latitudeLimit), accuracy: 1e-9)
    }

    /// A very small box should still yield a sane zoom rather than a wild one.
    func testTinyBoxZoomsInDeeply() {
        let zoom = MapFit.zoom(
            bounds: bounds(west: -0.00001, south: 37.7, east: -0.0000099, north: 37.70001),
            viewport: (width: 400, height: 400)
        )
        XCTAssertNotNil(zoom)
        XCTAssertGreaterThan(zoom!, 15)
    }
}