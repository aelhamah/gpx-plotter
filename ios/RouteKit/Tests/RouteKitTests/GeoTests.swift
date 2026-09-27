import XCTest
@testable import RouteKit

/// Port of `web/tests/geo.test.ts`.
final class GeoTests: XCTestCase {
    func testMercatorRoundTrips() {
        let lat = 39.5
        let lon = -107.32
        let back = Mercator.coordinate(y: Mercator.y(lat), x: Mercator.x(lon))
        XCTAssertEqual(back.lat, lat, accuracy: 1e-9)
        XCTAssertEqual(back.lon, lon, accuracy: 1e-9)
    }

    func testMercatorKeepsXNormalizedAndHandlesAntimeridian() {
        XCTAssertEqual(Mercator.x(-180), 0, accuracy: 1e-9)
        XCTAssertEqual(Mercator.x(180), 1, accuracy: 1e-9)
        let wrapped = Mercator.coordinate(y: 0.5, x: 0.999)
        XCTAssertEqual(wrapped.lat, 0, accuracy: 1e-6)
        XCTAssertEqual(wrapped.lon, 179.64, accuracy: 0.01)
    }

    func testRouteSamplesInterpolateLongSegmentsAndPreserveEndpoints() {
        let a = RoutePoint(lat: 0, lon: 0)
        let b = RoutePoint(lat: 0, lon: 1) // ~111 km along the equator
        let profile = Profile.routeSamples([a, b], stepMeters: 1000)
        XCTAssertGreaterThan(profile.count, 100)
        XCTAssertLessThan(profile.count, 120)
        XCTAssertEqual(profile.first, a)
        XCTAssertEqual(profile.last, b)
        for index in 1..<(profile.count - 1) {
            let gap = Haversine.meters(from: profile[index - 1], to: profile[index])
            XCTAssertLessThanOrEqual(gap, 2000)
            XCTAssertGreaterThan(gap, 400)
        }
    }

    func testRouteSamplesKeepShortSegmentsVerbatim() {
        let a = RoutePoint(lat: 39.5, lon: -107.3)
        let b = RoutePoint(lat: 39.501, lon: -107.3) // ~110 m
        XCTAssertEqual(Profile.routeSamples([a, b], stepMeters: 30 * 4), [a, b])
    }

    func testRouteSamplesDoNotJumpAcrossTheAntimeridian() {
        let a = RoutePoint(lat: 0, lon: 179.9)
        let b = RoutePoint(lat: 0, lon: -179.9)
        let profile = Profile.routeSamples([a, b], stepMeters: 2000)
        XCTAssertEqual(profile.first, a)
        XCTAssertEqual(profile.last, b)
        for point in profile {
            XCTAssertGreaterThan(abs(point.lon), 170)
        }
    }

    func testRouteSamplesPreserveVertexElevationsOnly() {
        let profile = Profile.routeSamples(
            [RoutePoint(lat: 0, lon: 0, elevation: 100), RoutePoint(lat: 0, lon: 1)],
            stepMeters: 1000
        )
        XCTAssertEqual(profile.first?.elevation, 100)
        XCTAssertNil(profile.last?.elevation)
        for point in profile.dropFirst().dropLast() {
            XCTAssertNil(point.elevation)
        }
    }

    func testSummaryAccumulatesGainAndLoss() {
        let summary = Slope.summary(for: [
            RoutePoint(lat: 0, lon: 0, elevation: 100),
            RoutePoint(lat: 0, lon: 0.001, elevation: 300),
            RoutePoint(lat: 0, lon: 0.002, elevation: 150),
        ])
        XCTAssertEqual(summary.gain ?? 0, 200, accuracy: 1e-6)
        XCTAssertEqual(summary.loss ?? 0, 150, accuracy: 1e-6)
        XCTAssertEqual(summary.min, 100)
        XCTAssertEqual(summary.max, 300)
    }

    func testSummaryReportsSteepestSegmentAngle() {
        // 100 m climb over ~111 m horizontal ≈ 42°
        let summary = Slope.summary(for: [
            RoutePoint(lat: 0, lon: 0, elevation: 100),
            RoutePoint(lat: 0, lon: 0.001, elevation: 200),
        ])
        XCTAssertEqual(summary.maxSlope ?? 0, 41.921, accuracy: 0.05)
    }

    func testSummaryIsEmptyWithFewerThanTwoElevations() {
        XCTAssertEqual(Slope.summary(for: [RoutePoint(lat: 0, lon: 0, elevation: 100)]), ProfileSummary())
        XCTAssertEqual(Slope.summary(for: [RoutePoint(lat: 0, lon: 0)]), ProfileSummary())
    }

    func testSegmentSlopeIgnoresMissingElevationsAndDuplicates() {
        XCTAssertNil(Slope.degrees(from: RoutePoint(lat: 0, lon: 0), to: RoutePoint(lat: 0, lon: 1)))
        XCTAssertNil(Slope.degrees(
            from: RoutePoint(lat: 0, lon: 0, elevation: 5),
            to: RoutePoint(lat: 0, lon: 0, elevation: 10)
        ))
    }

    func testElevationStatsOverRouteVertices() {
        let stats = Slope.stats(for: [
            RoutePoint(lat: 0, lon: 0, elevation: 10),
            RoutePoint(lat: 0, lon: 0.001, elevation: 30),
            RoutePoint(lat: 0, lon: 0.002, elevation: 5),
        ])
        XCTAssertEqual(stats.gain, 20)
        XCTAssertEqual(stats.loss, 25)
        XCTAssertEqual(stats.min, 5)
        XCTAssertEqual(stats.max, 30)
        XCTAssertEqual(Slope.stats(for: [RoutePoint(lat: 0, lon: 0)]), ElevationStats())
    }

    func testHaversineDistance() {
        let a = Coordinate(lat: 39.5, lon: -106.5)
        let b = Coordinate(lat: 39.6, lon: -106.5)
        XCTAssertEqual(Haversine.meters(from: a, to: b), 11119, accuracy: 50)
        XCTAssertEqual(Haversine.meters(from: a, to: a), 0)
        XCTAssertEqual(
            Haversine.routeLength([
                RoutePoint(lat: 0, lon: 0),
                RoutePoint(lat: 0, lon: 1),
                RoutePoint(lat: 0, lon: 2),
            ]),
            Haversine.meters(from: Coordinate(lat: 0, lon: 0), to: Coordinate(lat: 0, lon: 2)),
            accuracy: 1e-6
        )
    }

    func testProfileAxisStep() {
        XCTAssertEqual(Profile.axisStep(totalMeters: 0), 0)
        let cases: [(Double, Double)] = [
            (3000, 500),      // 3 km → 6 divisions of 500 m
            (10000, 2000),    // 10 km → 5 divisions of 2 km
            (40000, 10000),   // 40 km → 4 divisions of 10 km
            (500, 100),       // 500 m → 5 divisions of 100 m
            (75, 20),         // 75 m → ~4 divisions of 20 m
        ]
        for (total, expected) in cases {
            XCTAssertEqual(Profile.axisStep(totalMeters: total), expected, "total=\(total)")
        }
        for total in [800.0, 1600, 5000, 12000, 900_000] {
            XCTAssertLessThanOrEqual(Profile.axisStep(totalMeters: total), total)
        }
    }

    func testNearestProfileSample() {
        let cumulative = [0.0, 1000, 2000, 3000]
        XCTAssertEqual(Profile.nearestSample(cumulative: cumulative, to: 0), 0)
        XCTAssertEqual(Profile.nearestSample(cumulative: cumulative, to: 999), 1)
        XCTAssertEqual(Profile.nearestSample(cumulative: cumulative, to: 2499), 2)
        XCTAssertEqual(Profile.nearestSample(cumulative: cumulative, to: 4000), 3)
    }

    func testHexColorConversion() {
        XCTAssertEqual(RGBAColor(hex: "#22c55e"), RGBAColor(red: 34, green: 197, blue: 94))
        XCTAssertEqual(
            RGBAColor(hex: "#22c55e")?.withAlpha(0.5),
            RGBAColor(red: 34, green: 197, blue: 94, alpha: 0.5)
        )
        XCTAssertNil(RGBAColor(hex: "22c55e"))
        XCTAssertNil(RGBAColor(hex: "#22c55"))
    }

    func testMetersToKilometers() {
        XCTAssertEqual(Units.kilometers(1000), 1, accuracy: 1e-9)
        XCTAssertEqual(Units.kilometers(3218.688), 3.219, accuracy: 0.005)
    }

    func testUnitsFormatting() {
        XCTAssertEqual(Units.formatDistance(1609.344, system: .imperial), "1.00 mi")
        XCTAssertEqual(Units.formatDistance(1609.344, system: .metric), "1.61 km")
        XCTAssertEqual(Units.formatElevation(1000, system: .imperial, locale: Locale(identifier: "en_US")), "3,281 ft")
        XCTAssertEqual(Units.formatElevation(1000, system: .metric, locale: Locale(identifier: "en_US")), "1,000 m")
        XCTAssertEqual(Units.formatElevation(nil, system: .metric), "—")
        XCTAssertEqual(Units.formatSlope(42.3), "42°")
        XCTAssertEqual(Units.formatSlope(nil), "—")
        XCTAssertEqual(Units.formatDistanceAxis(2023, system: .imperial), "1.3")
        XCTAssertEqual(Units.formatDistanceAxis(30 * 1609.344, system: .imperial), "30")
        XCTAssertEqual(Units.formatDistanceAxis(1500, system: .metric), "1.5")
        XCTAssertEqual(Units.formatDistanceAxis(15000, system: .metric), "15")
    }

    func testNamesNormalization() {
        XCTAssertEqual(Names.normalizeRouteName("  Maroon Bells  ", id: 7), "Maroon Bells")
        XCTAssertEqual(Names.normalizeRouteName("", id: 3), "Route 3")
        XCTAssertEqual(Names.normalizeRouteName("   ", id: 3), "Route 3")
        XCTAssertEqual(Names.normalizeWaypointName(" Stream crossing ", index: 0), "Stream crossing")
        XCTAssertEqual(Names.normalizeWaypointName("", index: 2), "Waypoint 3")
        XCTAssertEqual(Names.normalizeWaypointName(" \t ", index: 0), "Waypoint 1")
    }

    func testColors() {
        XCTAssertFalse(Colors.routePalette.contains(Colors.trace))
        XCTAssertEqual(Set(Colors.routePalette).count, Colors.routePalette.count)
        XCTAssertEqual(Colors.trace, "#0ea5e9")
        XCTAssertNotEqual(Colors.routePalette[1], "#0ea5e9")
        XCTAssertEqual(Colors.routeColor(forID: 1), Colors.routePalette[0])
        XCTAssertEqual(Colors.routeColor(forID: 2), Colors.routePalette[1])
        XCTAssertEqual(Colors.routeColor(forID: 3), Colors.routePalette[2])
        XCTAssertEqual(Colors.routeColor(forID: Colors.routePalette.count + 1), Colors.routePalette[0])
        XCTAssertNotEqual(Colors.routeColor(forID: 2), Colors.trace)
    }

    func testConfigURLs() {
        let config = MapTilerConfig(apiKey: "test-key")
        XCTAssertTrue(config.mapStyleURL.contains("/maps/outdoor-v2/"))
        XCTAssertTrue(config.satelliteStyleURL.contains("/maps/satellite-v4/"))
        XCTAssertTrue(config.terrainURL.contains("terrain-rgb"))
        XCTAssertTrue(config.terrainTileURL.contains("terrain-rgb"))
        XCTAssertTrue(config.terrainTileURL.contains("{z}/{x}/{y}"))
        XCTAssertTrue(config.mapStyleURL.starts(with: "https://"))
    }

    func testTileMath() {
        // Test that tile math functions execute without error and return sensible values
        let tile = TileCoordinate(z: 14, x: 2627, y: 6331)
        let nw = TileMath.northWest(of: tile)
        XCTAssertGreaterThan(nw.lat, -90)
        XCTAssertLessThan(nw.lat, 90)
        XCTAssertGreaterThan(nw.lon, -180)
        XCTAssertLessThan(nw.lon, 180)
        let bounds = TileMath.bounds(of: tile)
        XCTAssertLessThan(bounds.west, bounds.east)
        XCTAssertLessThan(bounds.south, bounds.north)
        XCTAssertEqual(TileMath.groundSizeMeters(zoom: 0), TileMath.circumferenceMeters, accuracy: 1e-6)
        let mpp = TileMath.metersPerPixel(zoom: 14, midLatitude: 39.5)
        XCTAssertGreaterThan(mpp, 0)
    }

    func testAccuracyHalo() {
        let fix = LocationFix(lon: -106.5, lat: 39.5, accuracyMeters: 20)
        let ring = AccuracyHalo.ring(lon: fix.lon, lat: fix.lat, radiusMeters: 100)
        XCTAssertEqual(ring.count, 65)
        XCTAssertEqual(ring.first, ring.last)
        for point in ring {
            XCTAssertEqual(Haversine.meters(from: point, to: fix.coordinate), 100, accuracy: 0.5)
        }
        // Larger radius = larger ring
        let ringSmall = AccuracyHalo.ring(lon: -106.5, lat: 39.5, radiusMeters: 10)
        let ringLarge = AccuracyHalo.ring(lon: -106.5, lat: 39.5, radiusMeters: 1000)
        XCTAssertLessThan(ringSmall.map { Haversine.meters(from: $0, to: fix.coordinate) }.max()!,
                          ringLarge.map { Haversine.meters(from: $0, to: fix.coordinate) }.max()!)
        // Antimeridian wrap
        let ringWrap = AccuracyHalo.ring(lon: 179.999, lat: 0, radiusMeters: 2000)
        for point in ringWrap {
            XCTAssertGreaterThanOrEqual(point.lon, -180)
            XCTAssertLessThanOrEqual(point.lon, 180)
        }
    }

    func testZoomForAccuracy() {
        XCTAssertGreaterThan(AccuracyHalo.zoom(forAccuracyMeters: 10, latitude: 39.5),
                             AccuracyHalo.zoom(forAccuracyMeters: 1000, latitude: 39.5))
        XCTAssertLessThan(AccuracyHalo.zoom(forAccuracyMeters: 5000, latitude: 39.5),
                          AccuracyHalo.zoom(forAccuracyMeters: 50, latitude: 39.5))
        XCTAssertEqual(AccuracyHalo.zoom(forAccuracyMeters: 5, latitude: 39.5), 15)
        XCTAssertEqual(AccuracyHalo.zoom(forAccuracyMeters: 5, latitude: 39.5, maxZoom: 12), 12)
        XCTAssertGreaterThanOrEqual(AccuracyHalo.zoom(forAccuracyMeters: 500000, latitude: 39.5), 2)
        XCTAssertEqual(AccuracyHalo.zoom(forAccuracyMeters: .nan, latitude: 39.5),
                       AccuracyHalo.zoom(forAccuracyMeters: 30, latitude: 39.5))
        XCTAssertEqual(AccuracyHalo.zoom(forAccuracyMeters: 0, latitude: 39.5),
                       AccuracyHalo.zoom(forAccuracyMeters: 30, latitude: 39.5))
        XCTAssertGreaterThan(AccuracyHalo.zoom(forAccuracyMeters: 1000, latitude: 0),
                             AccuracyHalo.zoom(forAccuracyMeters: 1000, latitude: 70))
    }

    func testDefaultUnitSystem() {
        let system = Units.defaultUnitSystem(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(system, .imperial)
        let system2 = Units.defaultUnitSystem(locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(system2, .metric)
    }
}