import XCTest
@testable import RouteKit

/// A thread-safe stub: `SnapEngine` fans tile reads out across a task group,
/// so the URL log needs a lock even in tests.
final class StubHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    /// Returns (data, status) for a URL. Throw to simulate a transport error.
    var handler: @Sendable (String) throws -> (Data, Int)

    init(handler: @escaping @Sendable (String) throws -> (Data, Int)) {
        self.handler = handler
    }

    var requestedURLs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        urls = []
    }

    /// NSLock is unavailable from async contexts; serialize from a sync hop.
    private func record(_ url: String) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func data(from url: String) async throws -> (Data, URLResponse) {
        record(url)
        let (data, status) = try handler(url)
        let response = HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

/// Port of `web/tests/snapSources.test.ts`.
final class SnapEngineTests: XCTestCase {
    static let extent = 4096
    static let z = SnapTiles.snapMinZoom
    static let base = MapTilerConfig(baseURL: "https://proxy.test")

    /// Every tile URL the stub saw, as `source/z/x/y`.
    func requestedTiles(_ stub: StubHTTP) -> [String] {
        stub.requestedURLs
            .map { url in
                url.replacingOccurrences(of: ".*?/tiles/", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\.pbf.*$", with: "", options: .regularExpression)
            }
            .sorted()
    }

    func makeEngine(_ stub: StubHTTP, diskCache: TileCache? = nil) -> SnapEngine {
        SnapEngine(httpClient: stub, config: Self.base, diskCache: diskCache)
    }

    // MARK: - trailsNearPoint

    func testReturnsTheTrailLineNearAPointDecodedBackToLngLat() async throws {
        let lng = -105.321
        let lat = 39.685
        let coords = MVTEncode.tileCoordsFor(lng: lng, lat: lat, z: Self.z)
        let trailLngLat = [
            Coordinate(lat: lat, lon: lng - 0.001),
            Coordinate(lat: lat + 0.0002, lon: lng + 0.001),
        ]
        let part: [MVT.Pixel] = trailLngLat.map { point in
            let px = MVTEncode.lngLatToTilePx(lng: point.lon, lat: point.lat, z: Self.z, x: coords.x, y: coords.y, extent: Self.extent)
            return MVT.Pixel(x: Int(px.px.rounded()), y: Int(px.py.rounded()))
        }
        let bytes = MVTEncode.encodeTile([
            .init(
                name: "trail",
                extent: Self.extent,
                features: [
                    .init(type: 2, props: ["class": .string("hiking"), "name": .string("Test Loop")], parts: [part]),
                ]
            ),
        ])
        let stub = StubHTTP { _ in (bytes, 200) }
        let query = await makeEngine(stub).trailsNearPoint(lng: lng, lat: lat)

        XCTAssertEqual(query.lines.count, 1)
        XCTAssertEqual(query.lines[0].count, 2)
        XCTAssertEqual(query.lines[0][0].lon, trailLngLat[0].lon, accuracy: 1e-4)
        XCTAssertEqual(query.lines[0][0].lat, trailLngLat[0].lat, accuracy: 1e-4)
        XCTAssertEqual(query.lines[0][1].lon, trailLngLat[1].lon, accuracy: 1e-4)
        XCTAssertEqual(query.lines[0][1].lat, trailLngLat[1].lat, accuracy: 1e-4)
    }

    func testReturnsNoLinesWhenTheTileHasNoTrailLayer() async {
        let bytes = MVTEncode.encodeTile([.init(name: "landuse", extent: Self.extent, features: [])])
        let stub = StubHTTP { _ in (bytes, 200) }
        let query = await makeEngine(stub).trailsNearPoint(lng: -105.6, lat: 39.7)
        XCTAssertEqual(query.lines, [])
    }

    func testFallsBackToPathLikeTransportationLines() async {
        let lng = -106.81
        let lat = 39.655
        let coords = MVTEncode.tileCoordsFor(lng: lng, lat: lat, z: Self.z)
        func px(_ lon: Double, _ lat2: Double) -> MVT.Pixel {
            let p = MVTEncode.lngLatToTilePx(lng: lon, lat: lat2, z: Self.z, x: coords.x, y: coords.y, extent: Self.extent)
            return MVT.Pixel(x: Int(p.px.rounded()), y: Int(p.py.rounded()))
        }
        let pathLine = [px(lng - 0.0005, lat), px(lng + 0.0005, lat)]
        let roadLine = [px(lng - 0.0005, lat - 0.001), px(lng + 0.0005, lat - 0.001)]
        let planetBytes = MVTEncode.encodeTile([
            .init(
                name: "transportation",
                extent: Self.extent,
                features: [
                    .init(type: 2, props: ["class": .string("path")], parts: [pathLine]),
                    .init(type: 2, props: ["class": .string("primary")], parts: [roadLine]),
                    .init(type: 1, props: ["class": .string("path")], parts: [[MVT.Pixel(x: 0, y: 0)]]),
                ]
            ),
        ])
        let emptyBytes = MVTEncode.encodeTile([])
        let stub = StubHTTP { url in
            url.contains("/tiles/outdoor/") ? (emptyBytes, 200) : (planetBytes, 200)
        }
        let query = await makeEngine(stub).trailsNearPoint(lng: lng, lat: lat)
        XCTAssertEqual(query.lines.count, 1)
        XCTAssertEqual(query.lines[0][0].lon, lng - 0.0005, accuracy: 1e-4)
        XCTAssertEqual(query.lines[0][1].lon, lng + 0.0005, accuracy: 1e-4)
    }

    // MARK: - Which tiles a snap reads

    func testReadsAtTheZoomTheMapIsShowing() async {
        let stub = StubHTTP { _ in (Data(), 200) }
        stub.clear()
        _ = await makeEngine(stub).trailsNearPoint(lng: -106.52, lat: 39.53, zoom: 15)
        // A snap has to read the geometry the basemap is drawing, at the depth
        // it is drawing it: at z13 the tilesets have already dropped the minor
        // paths a tap is aiming at.
        let zooms = requestedTiles(stub).compactMap { tile -> Int? in
            Int(tile.split(separator: "/")[1])
        }
        XCTAssertTrue(zooms.contains(15))
        XCTAssertFalse(zooms.contains(13))
    }

    func testClampsEachTilesetToTheDeepestZoomItServes() async {
        let stub = StubHTTP { _ in (Data(), 200) }
        stub.clear()
        _ = await makeEngine(stub).trailsNearPoint(lng: -106.12, lat: 39.13, zoom: 15)
        // The planet tileset serves z15 but `outdoor` stops at z14, so at the
        // deepest snap zoom the marked-trail source has to step back rather
        // than request a tile the endpoint answers with a 400.
        let tiles = requestedTiles(stub)
        XCTAssertFalse(tiles.filter { $0.hasPrefix("v3/") }.isEmpty)
        XCTAssertFalse(tiles.filter { $0.hasPrefix("outdoor/") }.isEmpty)
        for tile in tiles {
            let parts = tile.split(separator: "/")
            let zoom = Int(parts[1]) ?? 0
            let max = tile.hasPrefix("outdoor/") ? SnapTiles.TilesetId.outdoor.maxZoom : SnapTiles.TilesetId.planet.maxZoom
            XCTAssertLessThanOrEqual(zoom, max)
        }
    }

    func testReadsOnlyTheTilesTheRadiusReaches() async {
        let stub = StubHTTP { _ in (Data(), 200) }
        let engine = makeEngine(stub)
        stub.clear()
        // Dead centre of a z15 tile, so a 40 m radius is ~470 m clear of every
        // edge.
        let centre = tileCentre(x: 7000, y: 13000, zoom: 15)
        _ = await engine.trailsNearPoint(lng: centre.lng, lat: centre.lat, zoom: 15)
        // One tile per source. Rounding the ring up unconditionally would cost
        // nine fetches per source for the ordinary case of tapping mid-tile.
        XCTAssertEqual(stub.requestedURLs.count, 2)
    }

    func testReadsTheNeighbouringTileWhenTheRadiusCrossesAnEdge() async {
        let stub = StubHTTP { _ in (Data(), 200) }
        let engine = makeEngine(stub)
        let x = 7100
        let y = 13100
        // 5 m inside this tile's western edge, with the full 250 m peak
        // radius, so a candidate 30 m further west lives in the neighbour.
        let lat = latOfTileY(Double(y) + 0.5, zoom: 15)
        let nearEdgeLng = tileWestEdge(x, zoom: 15) + 5 / metersPerDegreeLon(lat)

        stub.clear()
        _ = await engine.trailsNearPoint(lng: nearEdgeLng, lat: lat, zoom: 15, radiusMeters: PEAK_SNAP_METERS)
        XCTAssertTrue(requestedTiles(stub).contains("v3/15/\(x - 1)/\(y)"))

        // Pull the radius in and the neighbour is no longer reachable.
        stub.clear()
        _ = await engine.trailsNearPoint(lng: nearEdgeLng, lat: lat, zoom: 15, radiusMeters: 1)
        XCTAssertFalse(requestedTiles(stub).contains("v3/15/\(x - 1)/\(y)"))
    }

    // MARK: - Tile cache

    func testReusesADecodedTileInsteadOfRefetchingIt() async {
        let stub = StubHTTP { _ in (Data(), 200) }
        let engine = makeEngine(stub)
        let lng = -111.5
        let lat = 35.2
        _ = await engine.trailsNearPoint(lng: lng, lat: lat, zoom: Self.z)
        let afterFirst = stub.requestedURLs.count
        _ = await engine.trailsNearPoint(lng: lng, lat: lat, zoom: Self.z)
        XCTAssertEqual(stub.requestedURLs.count, afterFirst)
    }

    func testDoesNotCacheAFailedRead() async {
        let bytes = MVTEncode.encodeTile([
            .init(
                name: "trail",
                extent: Self.extent,
                features: [.init(type: 2, props: [:], parts: [[MVT.Pixel(x: 0, y: 0), MVT.Pixel(x: 10, y: 10)]])]
            ),
        ])
        let counter = CallCounter()
        let stub = StubHTTP { _ in
            // The first attempt is refused, as a rate limit or 5xx would be.
            if counter.increment() == 1 { return (Data(), 429) }
            return (bytes, 200)
        }
        let engine = makeEngine(stub)
        // Distinct coordinates so this is a fresh tile rather than a cache hit.
        let lng = -111.71
        let lat = 35.31
        let first = await engine.trailsNearPoint(lng: lng, lat: lat, zoom: Self.z)
        XCTAssertEqual(first.lines, [])
        let second = await engine.trailsNearPoint(lng: lng, lat: lat, zoom: Self.z)
        XCTAssertGreaterThan(second.lines.count, 0)
    }

    // MARK: - Failure reporting

    func testTotalFailureWhenEveryTileOfASnapFails() async {
        let stub = StubHTTP { _ in (Data(), 500) }
        let query = await makeEngine(stub).trailsNearPoint(lng: -112.4, lat: 36.9, zoom: Self.z)
        XCTAssertEqual(query.lines, [])
        // Without this, an outage and "there is no trail here" look the same.
        XCTAssertTrue(query.totalFailure)
    }

    func testSaysNothingWhenASnapSimplyFindsNoTrail() async {
        let bytes = MVTEncode.encodeTile([.init(name: "transportation", extent: Self.extent, features: [])])
        let stub = StubHTTP { _ in (bytes, 200) }
        let query = await makeEngine(stub).trailsNearPoint(lng: -113.4, lat: 37.9, zoom: Self.z)
        XCTAssertEqual(query.lines, [])
        XCTAssertFalse(query.totalFailure)
    }

    func testSaysNothingWhenOnlySomeTilesFail() async {
        // A single unreachable tile costs its own candidates, not the whole
        // snap.
        let bytes = MVTEncode.encodeTile([
            .init(
                name: "trail",
                extent: Self.extent,
                features: [.init(type: 2, props: [:], parts: [[MVT.Pixel(x: 0, y: 0), MVT.Pixel(x: 10, y: 10)]])]
            ),
        ])
        let stub = StubHTTP { url in
            url.contains("/tiles/outdoor/") ? (Data(), 500) : (bytes, 200)
        }
        let query = await makeEngine(stub).trailsNearPoint(lng: -114.4, lat: 38.9, zoom: Self.z)
        // The planet tiles answered, so this is a partial read — normal and
        // recoverable — even though the outdoor side failed entirely.
        XCTAssertFalse(query.totalFailure)
    }

    // MARK: - peaksNearPoint

    func testReturnsPeakCentersNamesAndElevations() async throws {
        let lng = -106.44
        let lat = 39.153
        let coords = MVTEncode.tileCoordsFor(lng: lng, lat: lat, z: Self.z)
        let peak = Coordinate(lat: lat + 0.0002, lon: lng + 0.0003)
        let px = MVTEncode.lngLatToTilePx(lng: peak.lon, lat: peak.lat, z: Self.z, x: coords.x, y: coords.y, extent: Self.extent)
        let bytes = MVTEncode.encodeTile([
            .init(
                name: "mountain_peak",
                extent: Self.extent,
                features: [
                    .init(
                        type: 1,
                        props: ["name": .string("Mount Massive"), "ele": .number(4398)],
                        parts: [[MVT.Pixel(x: Int(px.px.rounded()), y: Int(px.py.rounded()))]]
                    ),
                ]
            ),
        ])
        let stub = StubHTTP { _ in (bytes, 200) }
        let result = await makeEngine(stub).peaksNearPoint(lng: lng, lat: lat)

        XCTAssertEqual(result.peaks.count, 1)
        XCTAssertEqual(result.peaks[0].name, "Mount Massive")
        XCTAssertEqual(result.peaks[0].elevation, 4398)
        XCTAssertEqual(result.peaks[0].center.lon, peak.lon, accuracy: 1e-4)
        XCTAssertEqual(result.peaks[0].center.lat, peak.lat, accuracy: 1e-4)
    }

    func testIgnoresPeakNamesThatAreAbsent() async {
        let lng = -106.5
        let lat = 39.2
        let coords = MVTEncode.tileCoordsFor(lng: lng, lat: lat, z: Self.z)
        let px = MVTEncode.lngLatToTilePx(lng: lng, lat: lat, z: Self.z, x: coords.x, y: coords.y, extent: Self.extent)
        let bytes = MVTEncode.encodeTile([
            .init(
                name: "mountain_peak",
                extent: Self.extent,
                features: [
                    .init(
                        type: 1,
                        props: ["ele": .number(4102)],
                        parts: [[MVT.Pixel(x: Int(px.px.rounded()), y: Int(px.py.rounded()))]]
                    ),
                ]
            ),
        ])
        let stub = StubHTTP { _ in (bytes, 200) }
        let result = await makeEngine(stub).peaksNearPoint(lng: lng, lat: lat)
        XCTAssertNil(result.peaks[0].name)
        XCTAssertEqual(result.peaks[0].elevation, 4102)
    }

    func testReturnsNoPeaksWhenThePeakTilesCannotBeRead() async {
        let stub = StubHTTP { _ in (Data(), 404) }
        let result = await makeEngine(stub).peaksNearPoint(lng: -106.77, lat: 39.42, zoom: Self.z)
        XCTAssertTrue(result.peaks.isEmpty)
    }

    // MARK: - Offline disk cache (iOS-specific)

    func testReadsASnapTileFromTheSharedDiskCacheWithoutTouchingTheNetwork() async throws {
        let lng = -106.9
        let lat = 39.4
        let coords = MVTEncode.tileCoordsFor(lng: lng, lat: lat, z: SnapTiles.snapMinZoom)
        let trail = [Coordinate(lat: lat, lon: lng - 0.001), Coordinate(lat: lat, lon: lng + 0.001)]
        let part: [MVT.Pixel] = trail.map { point in
            let px = MVTEncode.lngLatToTilePx(lng: point.lon, lat: point.lat, z: SnapTiles.snapMinZoom, x: coords.x, y: coords.y, extent: Self.extent)
            return MVT.Pixel(x: Int(px.px.rounded()), y: Int(px.py.rounded()))
        }
        let bytes = MVTEncode.encodeTile([
            .init(
                name: "trail",
                extent: Self.extent,
                features: [.init(type: 2, props: [:], parts: [part])]
            ),
        ])
        // Warm the shared cache exactly as browsing would: the style's
        // `outdoor` source, pbf format, the tile the point falls in.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-cache-\(UUID().uuidString)", isDirectory: true)
        let disk = TileCache(directory: directory)
        await disk.store(bytes, for: TileCacheKey(source: "outdoor", z: SnapTiles.snapMinZoom, x: coords.x, y: coords.y, format: .pbf))

        // No config and a stub that would fail the test if it were asked.
        let stub = StubHTTP { _ in XCTFail("network should not be reached for a cached tile"); return (Data(), 500) }
        let engine = SnapEngine(httpClient: stub, config: nil, diskCache: disk)
        let query = await engine.trailsNearPoint(lng: lng, lat: lat, zoom: SnapTiles.snapMinZoom)

        XCTAssertEqual(query.lines.count, 1)
        XCTAssertEqual(query.lines[0][0].lon, trail[0].lon, accuracy: 1e-3)
    }

    // MARK: - Helpers (same arithmetic as the web suite)

    func tileCentre(x: Int, y: Int, zoom: Int) -> (lng: Double, lat: Double) {
        (lng: tileWestEdge(x, zoom: zoom) + (360 / pow(2, Double(zoom))) * 0.5, lat: latOfTileY(Double(y) + 0.5, zoom: zoom))
    }

    func tileWestEdge(_ x: Int, zoom: Int) -> Double {
        Double(x) / pow(2, Double(zoom)) * 360 - 180
    }

    func latOfTileY(_ fractionalY: Double, zoom: Int) -> Double {
        let n = Double.pi - (2 * Double.pi * fractionalY) / pow(2, Double(zoom))
        return atan(sinh(n)) * 180 / Double.pi
    }

    func metersPerDegreeLon(_ lat: Double) -> Double {
        111_320 * cos(lat * .pi / 180)
    }
}

/// An atomic counter the stub's Sendable closure can share.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
