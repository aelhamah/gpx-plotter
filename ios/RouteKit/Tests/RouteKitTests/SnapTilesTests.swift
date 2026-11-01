import XCTest
@testable import RouteKit

/// Port of `web/tests/snapTiles.test.ts`.
final class SnapTilesTests: XCTestCase {
    static let equatorMeters = 40_075_016.686

    // MARK: - snapZoom(for:)

    func testFollowsTheMapZoomInsideTheServedRange() {
        XCTAssertEqual(SnapTiles.snapZoom(for: 14), 14)
        XCTAssertEqual(SnapTiles.snapZoom(for: 15), 15)
    }

    func testNeverAsksForAZoomTheTilesetsDoNotHave() {
        XCTAssertEqual(SnapTiles.snapZoom(for: 18), SnapTiles.snapMaxZoom)
        XCTAssertEqual(SnapTiles.snapZoom(for: 20), SnapTiles.snapMaxZoom)
    }

    func testNeverDropsToAZoomWhereMinorPathsAreDiscarded() {
        // z12 emits no path-like transportation classes at all, so a tap
        // snapped there would find nothing even though the basemap is drawing
        // trails.
        XCTAssertEqual(SnapTiles.snapZoom(for: 8), SnapTiles.snapMinZoom)
        XCTAssertEqual(SnapTiles.snapZoom(for: 12.4), SnapTiles.snapMinZoom)
    }

    func testRoundsSoPanningAtAFractionalZoomReusesTheSameTiles() {
        XCTAssertEqual(SnapTiles.snapZoom(for: 14.2), 14)
        XCTAssertEqual(SnapTiles.snapZoom(for: 14.4), 14)
        XCTAssertEqual(SnapTiles.snapZoom(for: 14.6), 15)
        // The map reports a fractional zoom, but the cache key only changes at
        // a rounding boundary rather than on every pinch step.
        XCTAssertEqual(SnapTiles.snapZoom(for: 14.2), SnapTiles.snapZoom(for: 14.4))
    }

    func testFallsBackToAUsableZoomForAZoomTheMapCannotReport() {
        XCTAssertEqual(SnapTiles.snapZoom(for: .nan), SnapTiles.snapMinZoom)
        XCTAssertEqual(SnapTiles.snapZoom(for: .infinity), SnapTiles.snapMinZoom)
        XCTAssertEqual(SnapTiles.snapZoom(for: -.infinity), SnapTiles.snapMinZoom)
    }

    // MARK: - zoom(forTileset:at:)

    func testClampsEachTilesetToTheDeepestZoomItServes() {
        // outdoor stops at z14 and planet at z15; asking either for more is a
        // 400.
        XCTAssertEqual(SnapTiles.zoom(forTileset: .outdoor, at: 15), SnapTiles.TilesetId.outdoor.maxZoom)
        XCTAssertEqual(SnapTiles.zoom(forTileset: .planet, at: 15), SnapTiles.TilesetId.planet.maxZoom)
        XCTAssertEqual(SnapTiles.zoom(forTileset: .outdoor, at: 14), 14)
        XCTAssertEqual(SnapTiles.zoom(forTileset: .planet, at: 12), 12)
    }

    func testCannotBePushedBelowZero() {
        XCTAssertEqual(SnapTiles.zoom(forTileset: .planet, at: -4), 0)
    }

    func testKeepsEverySnapZoomWithinWhatAtLeastOneTilesetServes() {
        for zoom in 8...20 {
            XCTAssertLessThanOrEqual(SnapTiles.zoom(forTileset: .planet, at: zoom), SnapTiles.snapMaxZoom)
            XCTAssertLessThanOrEqual(SnapTiles.zoom(forTileset: .outdoor, at: zoom), SnapTiles.TilesetId.outdoor.maxZoom)
        }
    }

    // MARK: - tileSpanMeters

    func testShrinksWithZoomByAFactorOfTwo() {
        XCTAssertEqual(
            SnapTiles.tileSpanMeters(lat: 0, zoom: 14),
            SnapTiles.tileSpanMeters(lat: 0, zoom: 15) * 2,
            accuracy: 1e-6 * SnapTiles.tileSpanMeters(lat: 0, zoom: 14)
        )
    }

    func testIsTheFullWorldWidthAtTheEquatorOnZ0() {
        XCTAssertEqual(SnapTiles.tileSpanMeters(lat: 0, zoom: 0), Self.equatorMeters, accuracy: 0.001)
    }

    func testNarrowsWithTheCosineOfLatitude() {
        XCTAssertEqual(
            SnapTiles.tileSpanMeters(lat: 60, zoom: 14),
            SnapTiles.tileSpanMeters(lat: 0, zoom: 14) * 0.5,
            accuracy: 0.001
        )
    }

    func testStaysFiniteAtThePoles() {
        XCTAssertGreaterThan(SnapTiles.tileSpanMeters(lat: 90, zoom: 14), 0)
        XCTAssertTrue(SnapTiles.tileSpanMeters(lat: 90, zoom: 14).isFinite)
    }

    // MARK: - tilesNear

    static let lng = -106.52
    static let lat = 39.53
    static let peakRadiusM = 250.0

    func testReturnsOnlyTheContainingTileWhenTheRadiusCannotLeaveIt() {
        // The common case, and the one that decides cost: a 40 m trail snap
        // well inside a ~944 m z15 tile must not fan out to nine fetches per
        // source.
        let tiles = SnapTiles.tilesNear(lng: Self.lng, lat: Self.lat, zoom: 15, radiusMeters: 10)
        XCTAssertEqual(tiles, [SnapTiles.TileAddress(x: 6688, y: 12460)])
    }

    func testAddsTheNeighboursOnceTheRadiusReachesATileEdge() {
        XCTAssertGreaterThan(
            SnapTiles.tilesNear(lng: Self.lng, lat: Self.lat, zoom: 15, radiusMeters: Self.peakRadiusM).count,
            1
        )
    }

    func testFindsTheNeighbourHoldingACandidateJustAcrossAnEdge() {
        // A point 20 m from the western edge of its tile, with a 250 m radius:
        // a trail 30 m to the west lives in the tile this query has to include.
        let westEdge = tileX(Self.lng, zoom: 15)
        let nearWest = lngOfTileX(westEdge, zoom: 15) + 20 / metersPerDegreeLon(Self.lat)
        let tiles = SnapTiles.tilesNear(lng: nearWest, lat: Self.lat, zoom: 15, radiusMeters: Self.peakRadiusM)
        XCTAssertTrue(tiles.map(\.x).contains(westEdge - 1))

        // Pull the radius in and the neighbour is no longer reachable.
        let tight = SnapTiles.tilesNear(lng: nearWest, lat: Self.lat, zoom: 15, radiusMeters: 5)
        XCTAssertFalse(tight.map(\.x).contains(westEdge - 1))
    }

    func testCoversThePointItself() {
        for zoom in [14, 15] {
            let tiles = SnapTiles.tilesNear(lng: Self.lng, lat: Self.lat, zoom: zoom, radiusMeters: 40)
            let inside = tiles.contains { tileX(Self.lng, zoom: zoom) == $0.x && tileY(Self.lat, zoom: zoom) == $0.y }
            XCTAssertTrue(inside)
        }
    }

    func testNeverAsksForATileOutsideTheWorld() {
        let nearDateLine = SnapTiles.tilesNear(lng: 179.999, lat: 0, zoom: 15, radiusMeters: 4000)
        let max = Int(pow(2, Double(15))) - 1
        for tile in nearDateLine {
            XCTAssertLessThanOrEqual(tile.x, max)
            XCTAssertGreaterThanOrEqual(tile.y, 0)
        }
        // The far side of the antimeridian wraps, so the ring must still
        // contain the tile the point is actually in.
        XCTAssertTrue(nearDateLine.contains { $0.x == max })
    }

    func testClampsANegativeRadiusToTheContainingTile() {
        XCTAssertEqual(SnapTiles.tilesNear(lng: Self.lng, lat: Self.lat, zoom: 15, radiusMeters: -100).count, 1)
    }

    func testReturnsNothingForCoordinatesThatAreNotAPlace() {
        XCTAssertEqual(SnapTiles.tilesNear(lng: .nan, lat: Self.lat, zoom: 15, radiusMeters: 40), [])
        XCTAssertEqual(SnapTiles.tilesNear(lng: Self.lng, lat: .nan, zoom: 15, radiusMeters: 40), [])
    }

    func testNeverGrowsPastAThreeByThreeRing() {
        // Over-fetching is harmless; unbounded growth would be a request
        // storm.
        XCTAssertEqual(SnapTiles.tilesNear(lng: Self.lng, lat: Self.lat, zoom: 15, radiusMeters: 500_000).count, 9)
    }

    // MARK: - Helpers (same arithmetic as the web suite)

    func metersPerDegreeLon(_ lat: Double) -> Double {
        111_320 * cos(lat * .pi / 180)
    }

    func tileX(_ lng: Double, zoom: Int) -> Int {
        Int(((lng + 180) / 360 * pow(2, Double(zoom))).rounded(.down))
    }

    /// Longitude of a tile's western edge.
    func lngOfTileX(_ x: Int, zoom: Int) -> Double {
        Double(x) / pow(2, Double(zoom)) * 360 - 180
    }

    func tileY(_ lat: Double, zoom: Int) -> Int {
        let sinLat = sin(lat * .pi / 180)
        let t = (0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * Double.pi)) * pow(2, Double(zoom))
        return Int(t.rounded(.down))
    }
}
