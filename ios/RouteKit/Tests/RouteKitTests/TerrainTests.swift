import XCTest
@testable import RouteKit

/// Port of `web/tests/dem.test.ts`.
final class TerrainTests: XCTestCase {
    func testDecodeElevations() throws {
        // R=100, G=200, B=50 → -10000 + (100*65536 + 200*256 + 50) * 0.1
        let data: [UInt8] = [100, 200, 50, 255]
        let elevations = TerrainRGB.decodeElevations(data)
        XCTAssertEqual(elevations[0], 650485, accuracy: 1e-7)
    }

    func testDecodeElevationsOcean() throws {
        let data = [UInt8](repeating: 0, count: 4 * 2)
        let elevations = TerrainRGB.decodeElevations(data)
        XCTAssertEqual(elevations[0], -10000)
        XCTAssertEqual(elevations[1], -10000)
    }

    func testSlopeRgbaPaintsEveryPixel() throws {
        let width = 64
        let height = 64
        let perPixel: Float = 500
        var elevations = [Float](repeating: 0, count: width * height)
        for j in 0..<height {
            for i in 0..<width {
                elevations[j * width + i] = Float(j) * perPixel
            }
        }
        let rgba = SlopeBands.slopeRgba(elevations: elevations, width: width, height: height, ppx: 100)
        XCTAssertEqual(rgba.count, width * height * 4)
        for index in [0, 3, 63 * 64 * 4 + 3, (63 * 64 + 63) * 4 + 3] {
            XCTAssertGreaterThan(rgba[index], 0)
        }
    }

    func testSlopeRgbaSteepRampNotGreen() throws {
        let width = 32
        let height = 32
        let perPixel: Float = 500
        var elevations = [Float](repeating: 0, count: width * height)
        for j in 0..<height {
            for i in 0..<width {
                elevations[j * width + i] = Float(j) * perPixel
            }
        }
        let steep = SlopeBands.slopeRgba(elevations: elevations, width: width, height: height, ppx: 100)
        let _ = steep[0], g = steep[1], _ = steep[2]
        XCTAssertLessThan(g, 200)
    }

    func testSlopeRgbaFlatWithLargePPX() throws {
        let width = 32
        let height = 32
        let perPixel: Float = 500
        var elevations = [Float](repeating: 0, count: width * height)
        for j in 0..<height {
            for i in 0..<width {
                elevations[j * width + i] = Float(j) * perPixel
            }
        }
        let flat = SlopeBands.slopeRgba(elevations: elevations, width: width, height: height, ppx: 100 * 256)
        XCTAssertEqual(flat[0], 34)
        XCTAssertEqual(flat[1], 197)
        XCTAssertEqual(flat[2], 94)
    }

    func testSlopeBandColorsAtMidBand() throws {
        let testCases: [(degrees: Double, expected: (UInt8, UInt8, UInt8))] = [
            (25, (234, 179, 8)),
            (32, (249, 115, 22)),
            (42, (168, 85, 247)),
        ]
        for (degrees, expected) in testCases {
            let perPixel = 200 * tan(degrees * .pi / 180)
            let width = 64
            let height = 64
            var elevations = [Float](repeating: 0, count: width * height)
            for j in 0..<height {
                for i in 0..<width {
                    elevations[j * width + i] = Float(j) * Float(perPixel)
                }
            }
            let rgba = SlopeBands.slopeRgba(elevations: elevations, width: width, height: height, ppx: 100)
            XCTAssertEqual(rgba[0], expected.0, "at \(degrees)°")
            XCTAssertEqual(rgba[1], expected.1, "at \(degrees)°")
            XCTAssertEqual(rgba[2], expected.2, "at \(degrees)°")
        }
    }

    func testSlopeBandColorHexBoundaries() throws {
        let boundaries: [(degrees: Double, expected: String)] = [
            (0, "#22c55e"), (19.9, "#22c55e"),
            (20, "#eab308"), (29.9, "#eab308"),
            (30, "#f97316"), (34.9, "#f97316"),
            (35, "#ef4444"), (39.9, "#ef4444"),
            (40, "#a855f7"), (44.9, "#a855f7"),
            (45, "#111827"), (89, "#111827"),
        ]
        for (degrees, expected) in boundaries {
            XCTAssertEqual(SlopeBands.slopeBandColorHex(degrees), expected, "at \(degrees)°")
        }
    }

    func testMetersPerPixel() throws {
        let mpp = SlopeBands.metersPerPixel(zoom: 14, midLatitude: 39.5)
        XCTAssertGreaterThan(mpp, 0)
        XCTAssertEqual(mpp, 7.35, accuracy: 0.5)
    }

    func testBilinearSample() throws {
        let tile = TerrainTile(width: 256, height: 256, elevations: [Float](repeating: 1000, count: 256 * 256))
        let sample = TerrainRGB.bilinearSample(tile: tile, fx: 128.5, fy: 128.5)
        XCTAssertEqual(sample ?? 0, 1000, accuracy: 1e-6)

        var elevations = [Float](repeating: 0, count: 256 * 256)
        for j in 0..<256 {
            for i in 0..<256 {
                elevations[j * 256 + i] = Float(j)
            }
        }
        let tile2 = TerrainTile(width: 256, height: 256, elevations: elevations)
        let sample2 = TerrainRGB.bilinearSample(tile: tile2, fx: 0, fy: 100.5)
        XCTAssertEqual(sample2 ?? 0, 100.5, accuracy: 1e-6)
    }
}