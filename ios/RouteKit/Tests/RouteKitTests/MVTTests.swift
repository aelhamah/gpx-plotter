import XCTest
@testable import RouteKit

/// Port of `web/tests/mvt.test.ts`.
final class MVTTests: XCTestCase {
    static let extent = 4096

    func trailFixture() -> Data {
        MVTEncode.encodeTile([
            .init(
                name: "trail",
                extent: Self.extent,
                features: [
                    .init(
                        type: 2,
                        props: ["class": .string("hiking"), "name": .string("Elk Loop")],
                        parts: [[MVT.Pixel(x: 100, y: 200), MVT.Pixel(x: 140, y: 260), MVT.Pixel(x: 180, y: 240)]]
                    ),
                    .init(
                        type: 2,
                        props: ["class": .string("foot")],
                        parts: [
                            [MVT.Pixel(x: 10, y: 10), MVT.Pixel(x: 20, y: 20)],
                            [MVT.Pixel(x: 50, y: 50), MVT.Pixel(x: 60, y: 60)],
                        ]
                    ),
                ]
            ),
            .init(
                name: "mountain_peak",
                extent: Self.extent,
                features: [
                    .init(
                        type: 1,
                        props: ["name": .string("Mount Sentinel"), "ele": .number(2398)],
                        parts: [[MVT.Pixel(x: 300, y: 400)]]
                    ),
                ]
            ),
        ])
    }

    func testDecodesLayerNamesExtentAndFeatureProperties() throws {
        let layers = try MVT.decodeTile(trailFixture())
        XCTAssertEqual(layers.count, 2)

        XCTAssertNotNil(MVT.layer(named: "trail", in: layers))
        XCTAssertNotNil(MVT.layer(named: "mountain_peak", in: layers))
        XCTAssertNil(MVT.layer(named: "nope", in: layers))

        for layer in layers { XCTAssertEqual(layer.extent, Self.extent) }

        let trails = try XCTUnwrap(MVT.layer(named: "trail", in: layers))
        XCTAssertEqual(trails.features.count, 2)
        XCTAssertEqual(trails.features[0].type, 2)
        XCTAssertEqual(trails.features[0].props, ["class": .string("hiking"), "name": .string("Elk Loop")])

        let peaks = try XCTUnwrap(MVT.layer(named: "mountain_peak", in: layers))
        XCTAssertEqual(peaks.features[0].props, ["name": .string("Mount Sentinel"), "ele": .number(2398)])
    }

    func testDecodesLineStringGeometryToExactTilePixels() throws {
        let layers = try MVT.decodeTile(trailFixture())
        let trail = try XCTUnwrap(MVT.layer(named: "trail", in: layers))
        XCTAssertEqual(trail.features[0].parts, [[
            MVT.Pixel(x: 100, y: 200), MVT.Pixel(x: 140, y: 260), MVT.Pixel(x: 180, y: 240),
        ]])
    }

    func testKeepsMultiLineStringPartsSeparate() throws {
        let layers = try MVT.decodeTile(trailFixture())
        let trail = try XCTUnwrap(MVT.layer(named: "trail", in: layers))
        XCTAssertEqual(trail.features[1].parts, [
            [MVT.Pixel(x: 10, y: 10), MVT.Pixel(x: 20, y: 20)],
            [MVT.Pixel(x: 50, y: 50), MVT.Pixel(x: 60, y: 60)],
        ])
    }

    func testDecodesPointGeometryAndDefaultExtent() throws {
        let bytes = MVTEncode.encodeTile([
            .init(
                name: "mountain_peak",
                features: [.init(type: 1, props: ["name": .string("P")], parts: [[MVT.Pixel(x: 1, y: 2)]])]
            ),
        ])
        let layers = try MVT.decodeTile(bytes)
        let peaks = try XCTUnwrap(MVT.layer(named: "mountain_peak", in: layers))
        XCTAssertEqual(peaks.extent, 4096)
        XCTAssertEqual(peaks.features[0].parts, [[MVT.Pixel(x: 1, y: 2)]])
    }

    func testHandlesAClosedPolygonRing() throws {
        let bytes = MVTEncode.encodeTile([
            .init(
                name: "landuse",
                extent: Self.extent,
                features: [
                    .init(
                        type: 3,
                        props: ["class": .string("wood")],
                        parts: [[
                            MVT.Pixel(x: 0, y: 0), MVT.Pixel(x: 100, y: 0),
                            MVT.Pixel(x: 100, y: 100), MVT.Pixel(x: 0, y: 100),
                        ]],
                        close: true
                    ),
                ]
            ),
        ])
        let layers = try MVT.decodeTile(bytes)
        let landuse = try XCTUnwrap(MVT.layer(named: "landuse", in: layers))
        XCTAssertEqual(landuse.features[0].parts, [[
            MVT.Pixel(x: 0, y: 0), MVT.Pixel(x: 100, y: 0),
            MVT.Pixel(x: 100, y: 100), MVT.Pixel(x: 0, y: 100),
        ]])
    }

    func testTilePointMapsBackToTheCorrectWorldPositions() {
        let z = 1
        let x = 0
        let y = 1 // bottom half
        let nw = MVT.tilePointToCoordinate(z: z, x: x, y: y, extent: Self.extent, px: 0, py: 0)
        XCTAssertEqual(nw.lon, -180, accuracy: 1e-5)
        XCTAssertEqual(nw.lat, 0, accuracy: 1e-5)

        let se = MVT.tilePointToCoordinate(z: z, x: x, y: y, extent: Self.extent, px: 4096, py: 4096)
        XCTAssertEqual(se.lon, 0, accuracy: 1e-5)
        XCTAssertEqual(se.lat, -85.05, accuracy: 0.1)

        let center = MVT.tilePointToCoordinate(z: z, x: x, y: y, extent: Self.extent, px: 2048, py: 2048)
        XCTAssertEqual(center.lon, -90, accuracy: 1e-5)
    }
}
