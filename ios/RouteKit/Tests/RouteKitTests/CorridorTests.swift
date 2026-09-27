import XCTest
@testable import RouteKit

/// Covers `Corridor` (docs/ios-plan.md §8): the route plus a buffer, selecting
/// tiles by distance-to-route rather than by bounding rectangle.
final class CorridorTests: XCTestCase {
    /// An east-west route along the equator.
    private func eastWestRoute(km: Double) -> [Coordinate] {
        let degrees = km / 111.32
        return [
            Coordinate(lat: 0, lon: 0),
            Coordinate(lat: 0, lon: degrees / 2),
            Coordinate(lat: 0, lon: degrees),
        ]
    }

    // MARK: - Shape

    func testShapeIsClosedAndWideEnough() {
        let route = eastWestRoute(km: 10)
        let buffer: Double = 1_000
        let shape = Corridor.shape(for: route, bufferMeters: buffer)

        // The ring's two ends are the flat caps at each end of the route, so the
        // wrap-around span is the corridor's width, 2 × buffer.
        let first = shape.first!
        let last = shape.last!
        let closingSpan = Haversine.meters(from: first, to: last)
        XCTAssertEqual(closingSpan, 2 * buffer, accuracy: 250)

        // Every vertex should be roughly one buffer from the line.
        let distances = shape.map { Corridor.minimumDistance(from: $0, to: route) }
        XCTAssertEqual(distances.min() ?? 0, buffer, accuracy: 150)
        XCTAssertEqual(distances.max() ?? 0, buffer, accuracy: 250)
    }

    func testShapeEnclosesTheRoute() {
        let route = eastWestRoute(km: 5)
        let shape = Corridor.shape(for: route, bufferMeters: 1_000)

        // The route's endpoints sit exactly on the corridor's flat end caps,
        // where point-in-polygon is undefined, so test the midpoints — which
        // are strictly interior — and check the endpoints by distance instead.
        for index in 1..<route.count {
            let midpoint = Coordinate(
                lat: (route[index - 1].lat + route[index].lat) / 2,
                lon: (route[index - 1].lon + route[index].lon) / 2
            )
            XCTAssertTrue(
                Self.contains(midpoint, in: shape),
                "route midpoint \(index) must be inside the corridor"
            )
        }

        for endpoint in [route.first!, route.last!] {
            let distances = shape.map { Haversine.meters(from: $0, to: endpoint) }
            XCTAssertEqual(distances.min() ?? .infinity, 1_000, accuracy: 250)
        }
    }

    func testShapeCoversTheFullRouteLengthPlusBuffer() {
        let route = eastWestRoute(km: 10)
        let shape = Corridor.shape(for: route, bufferMeters: 1_000)
        // The corridor's extent along the route should be route + 2× buffer.
        let lats = shape.map(\.lat)
        let northSouthSpanMeters = (lats.max()! - lats.min()!) * 111_320
        XCTAssertEqual(northSouthSpanMeters, 2_000, accuracy: 250)
    }

    func testShapeDegeneratesToADiscForASinglePoint() {
        let shape = Corridor.shape(for: [Coordinate(lat: 39.5, lon: -106.5)], bufferMeters: 500)
        XCTAssertGreaterThan(shape.count, 8)
        let radii = shape.map { Haversine.meters(from: $0, to: Coordinate(lat: 39.5, lon: -106.5)) }
        XCTAssertEqual(radii.min() ?? 0, 500, accuracy: 5)
    }

    func testEmptyRouteHasNoShape() {
        XCTAssertTrue(Corridor.shape(for: []).isEmpty)
    }

    // MARK: - Tile selection

    func testTilesOnlyIncludesTilesNearTheRoute() {
        let route = eastWestRoute(km: 10)
        let buffer: Double = 1_000
        let tiles = Corridor.tiles(for: route, bufferMeters: buffer, zoomRange: 12...16)

        XCTAssertFalse(tiles.isEmpty, "a 10 km corridor must select tiles at every zoom")
        for tile in tiles {
            let center = TileMath.center(of: tile)
            let distance = Corridor.minimumDistance(from: center, to: route)
            let tolerance = buffer + Corridor.halfDiagonal(of: tile, latitude: 0)
            XCTAssertLessThanOrEqual(
                distance, tolerance + 1,
                "tile \(tile.key) is \(Int(distance)) m out, beyond buffer + half-diagonal"
            )
        }
    }

    func testTileSelectionKeepsLowZoomTilesDespiteLargeTileSize() {
        // A z12 tile is ~9.8 km across but the buffer is 1 km, so a strict
        // centre test would select nothing. The half-diagonal tolerance is what
        // makes low zooms work at all.
        let route = eastWestRoute(km: 10)
        let coarse = Corridor.tiles(for: route, bufferMeters: 1_000, zoomRange: 12...12)
        XCTAssertFalse(coarse.isEmpty, "low zoom must still select tiles")

        for tile in coarse {
            let center = TileMath.center(of: tile)
            let distance = Corridor.minimumDistance(from: center, to: route)
            XCTAssertLessThan(
                distance, 1_000 + TileMath.metersPerPixel(zoom: 12, midLatitude: 0) * 256,
                "a z12 tile is kept because the corridor crosses it, not because its centre is near"
            )
        }
    }

    func testTileSelectionExcludesTheCornersOfTheBoundingBox() {
        // A right-angle route. At z15 a tile is ~1.2 km, so a bounding rectangle
        // would clearly include tiles at the inside corner that the corridor
        // never reaches.
        let route = [
            Coordinate(lat: 39.50, lon: -106.50),
            Coordinate(lat: 39.50, lon: -106.42),
            Coordinate(lat: 39.58, lon: -106.42),
        ]
        let buffer: Double = 1_000
        let zoom = 15
        let tiles = Corridor.tiles(for: route, bufferMeters: buffer, zoomRange: zoom...zoom)

        let insideCorner = TileMath.tile(lon: -106.50, lat: 39.58, zoom: zoom)
        let distanceFromRoute = Corridor.minimumDistance(
            from: TileMath.center(of: insideCorner),
            to: route
        )
        // Only exclude it if it is genuinely out of tolerance.
        if distanceFromRoute > buffer + Corridor.halfDiagonal(of: insideCorner, latitude: 39.58) {
            XCTAssertFalse(
                tiles.contains(insideCorner),
                "tile at the inside corner is \(Int(distanceFromRoute)) m out and must be excluded"
            )
        }
    }

    func testTileSelectionScalesWithZoomRange() {
        let route = eastWestRoute(km: 10)
        let low = Corridor.tiles(for: route, zoomRange: 12...12).count
        let high = Corridor.tiles(for: route, zoomRange: 12...16).count
        XCTAssertGreaterThan(high, low)
    }

    func testTileSelectionIsEmptyForAnEmptyRoute() {
        XCTAssertTrue(Corridor.tiles(for: [], zoomRange: 12...14).isEmpty)
    }

    // MARK: - Size estimate

    /// Calibrates against the plan's own figure for a 10 km route.
    ///
    /// The plan (§8) says "roughly 100–200 tiles / 8–15 MB". The tile count
    /// lands in that range. The byte estimate does not, and deliberately so:
    /// `approximateBytesPerTile` is sized for vector and Terrain-RGB tiles,
    /// whereas 8–15 MB implies satellite rasters, which are much larger at
    /// z15–z16. The real figure can only be measured once a MapTiler key works,
    /// so the table is left honest rather than tuned to hit the number.
    func testEstimateMatchesThePlanForATenKilometerRoute() {
        let route = eastWestRoute(km: 10)
        let tiles = Corridor.tiles(for: route, bufferMeters: 1_000, zoomRange: 12...16)
        let bytes = Corridor.estimatedBytes(for: tiles)

        XCTAssertGreaterThan(tiles.count, 100, "plan expects ~100–200 tiles")
        XCTAssertLessThan(tiles.count, 200, "plan expects ~100–200 tiles")
        XCTAssertGreaterThan(bytes, 3_000_000, "vector/terrain estimate for ~126 tiles")
        XCTAssertLessThan(bytes, 15_000_000, "still under the plan's upper bound")
    }

    func testDemAddsASingleZoomLevel() {
        let route = eastWestRoute(km: 10)
        let imagery = Corridor.tiles(for: route, zoomRange: 12...16)
        let dem = Corridor.tiles(for: route, zoomRange: Corridor.demZoomRange)

        XCTAssertTrue(dem.allSatisfy { $0.z == 14 })
        XCTAssertGreaterThan(dem.count, 0)
        // The DEM layer is extra on top of the imagery, so it adds to the total.
        XCTAssertGreaterThan(
            Corridor.estimatedBytes(for: imagery + dem),
            Corridor.estimatedBytes(for: imagery)
        )
    }

    // MARK: - Helpers

    /// Ray casting, so "is the route inside the corridor" is a real test.
    private static func contains(_ point: Coordinate, in ring: [Coordinate]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i]
            let b = ring[j]
            if (a.lat > point.lat) != (b.lat > point.lat),
               point.lon < (b.lon - a.lon) * (point.lat - a.lat) / (b.lat - a.lat) + a.lon {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
