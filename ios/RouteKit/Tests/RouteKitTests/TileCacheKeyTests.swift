import XCTest
@testable import RouteKit

/// The cache key is what makes an offline map correct rather than merely
/// present, so these are mostly about the source being part of the identity.
final class TileCacheKeyTests: XCTestCase {

    // MARK: - The source is part of the identity

    /// A style's sources are different payloads at the same `z/x/y`, so they
    /// must not share a key. This is the regression: a `z/x/y`-only key makes
    /// every source read the first one to be cached, and makes a prefetch of
    /// four sources fetch one of them.
    func testDifferentSourcesAtTheSameTileAreDifferentKeys() {
        let tile = TileCoordinate(z: 12, x: 656, y: 1583)
        let basemap = TileCacheKey(tile: tile, source: "outdoor")
        let contours = TileCacheKey(tile: tile, source: "contours")
        let labels = TileCacheKey(tile: tile, source: "maptiler_planet")
        let dem = TileCacheKey(tile: tile, source: "terrain", format: .webp)

        let keys = [basemap, contours, labels, dem]
        XCTAssertEqual(Set(keys).count, keys.count, "every source needs its own key")
        XCTAssertEqual(Set(keys.map(\.fileName)).count, keys.count, "and its own file on disk")
    }

    func testSameSourceAndTileIsTheSameKey() {
        let a = TileCacheKey(source: "outdoor", z: 12, x: 656, y: 1583)
        let b = TileCacheKey(source: "outdoor", z: 12, x: 656, y: 1583)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.fileName, b.fileName)
    }

    func testFormatIsPartOfTheIdentity() {
        let vector = TileCacheKey(source: "terrain", z: 14, x: 2625, y: 6333, format: .webp)
        let sameTileAsPng = TileCacheKey(source: "terrain", z: 14, x: 2625, y: 6333, format: .png)
        XCTAssertNotEqual(vector, sameTileAsPng)
        XCTAssertNotEqual(vector.fileName, sameTileAsPng.fileName)
    }

    // MARK: - Names and paths

    func testFileNameCarriesTheSourceAndTheFormat() {
        let key = TileCacheKey(source: "maptiler_planet", z: 14, x: 2625, y: 6333)
        XCTAssertEqual(key.fileName, "maptiler_planet_14_2625_6333.pbf")
        XCTAssertEqual(key.description, "maptiler_planet/14/2625/6333.pbf")
    }

    func testLoopbackTemplateAndPathAgree() {
        let key = TileCacheKey(source: "satellite", z: 12, x: 656, y: 1583, format: .jpg)
        XCTAssertEqual(key.loopbackTemplate, "/tiles/satellite/{z}/{x}/{y}.jpg")

        let expanded = key.loopbackTemplate
            .replacingOccurrences(of: "{z}", with: "12")
            .replacingOccurrences(of: "{x}", with: "656")
            .replacingOccurrences(of: "{y}", with: "1583")
        XCTAssertEqual(expanded, key.loopbackPath)
    }

    /// The server reads the key back out of the path MapLibre requests, so the
    /// two directions have to be inverses.
    func testPathRoundTrips() {
        for format in TileFormat.allCases {
            let key = TileCacheKey(source: "outdoor", z: 13, x: 1313, y: 3167, format: format)
            XCTAssertEqual(TileCacheKey.parse(path: key.loopbackPath), key, "\(format)")
        }
    }

    func testParseRejectsOtherPaths() {
        XCTAssertNil(TileCacheKey.parse(path: "/style.json"))
        XCTAssertNil(TileCacheKey.parse(path: "/slope/12/656/1583.png"))
        XCTAssertNil(TileCacheKey.parse(path: "/tiles/outdoor/12/656/1583"))
        XCTAssertNil(TileCacheKey.parse(path: "/tiles/outdoor/12/656/1583.bogus"))
        XCTAssertNil(TileCacheKey.parse(path: "/tiles/outdoor/a/656/1583.pbf"))
    }

    // MARK: - Upstream

    func testUpstreamSubstitutesTheTemplate() {
        let key = TileCacheKey(source: "outdoor", z: 12, x: 656, y: 1583)
        let url = key.upstreamURL(
            template: "https://api.maptiler.com/tiles/outdoor/{z}/{x}/{y}.pbf?key=abc"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://api.maptiler.com/tiles/outdoor/12/656/1583.pbf?key=abc"
        )
    }

    func testUpstreamRejectsAnUnusableTemplate() {
        let key = TileCacheKey(source: "outdoor", z: 12, x: 656, y: 1583)
        XCTAssertNil(key.upstreamURL(template: ""))
    }

    // MARK: - Formats

    func testContentTypePerFormat() {
        XCTAssertEqual(TileFormat.pbf.contentType, "application/x-protobuf")
        XCTAssertEqual(TileFormat.jpg.contentType, "image/jpeg")
        XCTAssertEqual(TileFormat.webp.contentType, "image/webp")
        XCTAssertEqual(TileFormat.png.contentType, "image/png")
    }

    func testEveryMeasuredSourceIsCoveredAtEveryDownloadedZoom() {
        for source in TileSourceSize.measured.keys {
            for zoom in 12...14 {
                XCTAssertGreaterThan(
                    TileSourceSize.approximateBytes(source: source, format: .pbf, zoom: zoom),
                    0,
                    "\(source) at z\(zoom)"
                )
            }
        }
    }

    /// The reason this table exists: the style's tile sets are not within a
    /// factor of two of each other, so a single average would be wrong for all
    /// but one of them.
    func testMeasuredSourcesDifferByOrdersOfMagnitude() {
        let outdoor = TileSourceSize.approximateBytes(source: "outdoor", format: .pbf, zoom: 13)
        let contours = TileSourceSize.approximateBytes(source: "contours", format: .pbf, zoom: 13)
        let dem = TileSourceSize.approximateBytes(source: "terrain", format: .webp, zoom: 13)

        XCTAssertGreaterThan(contours, outdoor * 10, "contours dwarf the basemap geometry")
        XCTAssertGreaterThan(dem, outdoor * 10, "the DEM dwarfs both")
    }

    func testSatelliteIsBiggerThanTheBasemapItSitsUnder() {
        let imagery = TileSourceSize.approximateBytes(source: "satellite", format: .jpg, zoom: 14)
        let basemap = TileSourceSize.approximateBytes(source: "outdoor", format: .pbf, zoom: 14)
        XCTAssertGreaterThan(imagery, basemap * 10)
    }

    /// An unmeasured tileset falls back to its format, so a source MapTiler adds
    /// later still gets a sane estimate rather than zero.
    func testAnUnmeasuredSourceFallsBackToItsFormat() {
        XCTAssertEqual(
            TileSourceSize.approximateBytes(source: "some-future-tileset", format: .jpg, zoom: 13),
            TileFormat.jpg.approximateBytes(atZoom: 13)
        )
        XCTAssertGreaterThan(
            TileSourceSize.approximateBytes(source: "outdoor", format: .pbf, zoom: 3),
            0,
            "a zoom outside the measurements still estimates something"
        )
    }
}
