import XCTest
@testable import RouteKit

/// Port of `web/tests/gpx.test.ts`.
final class GPXTests: XCTestCase {
    func roundTrip(routes: [Route], waypoints: [Waypoint], name: String? = nil) throws -> ParsedGPX {
        let xml = GPXWriter.export(routes: routes, waypoints: waypoints, name: name)
        XCTAssertTrue(xml.contains("creator=\"GPX Plotter\""))
        return try parseGPX(xml)
    }

    func testRoundTripNameAndCoordinatesWithElevation() throws {
        let routes = [Route(id: 1, name: "Maroon Bells", points: [
            RoutePoint(lat: 39.0998, lon: -106.9445, elevation: 2400.536),
            RoutePoint(lat: 39.1, lon: -106.945),
        ], color: "#e11d48")]
        let parsed = try roundTrip(routes: routes, waypoints: [])
        XCTAssertEqual(parsed.routes.count, 1)
        XCTAssertEqual(parsed.routes[0].name, "Maroon Bells")
        XCTAssertEqual(parsed.routes[0].points.count, 2)
        XCTAssertEqual(parsed.routes[0].points[0].lat, 39.0998, accuracy: 1e-6)
        XCTAssertEqual(parsed.routes[0].points[0].lon, -106.9445, accuracy: 1e-6)
        XCTAssertEqual(parsed.routes[0].points[0].elevation ?? 0, 2400.536, accuracy: 0.01)
        XCTAssertNil(parsed.routes[0].points[1].elevation)
    }

    func testEscapesXMLSpecialCharacters() throws {
        let routes = [Route(id: 1, name: "A & B <C/>", points: [RoutePoint(lat: 0, lon: 0)], color: "#e11d48")]
        let xml = GPXWriter.export(routes: routes, waypoints: [])

        // The writer must escape, and the parser must decode back to the original.
        let amp = String(UnicodeScalar(0x26)!) + "amp;"
        let lt = String(UnicodeScalar(0x26)!) + "lt;"
        let gt = String(UnicodeScalar(0x26)!) + "gt;"
        XCTAssertTrue(xml.contains("A \(amp) B \(lt)C/\(gt)"))

        let parsed = try parseGPX(xml)
        XCTAssertEqual(parsed.routes[0].name, "A & B <C/>")
    }

    func testMultipleRoutesAndWaypoints() throws {
        let routes = [
            Route(id: 1, name: "First", points: [RoutePoint(lat: 1, lon: 2), RoutePoint(lat: 3, lon: 4)], color: "#e11d48"),
            Route(id: 2, name: "Second", points: [RoutePoint(lat: 5, lon: 6), RoutePoint(lat: 7, lon: 8)], color: "#2563eb"),
        ]
        let waypoints = [Waypoint(lat: 9, lon: 10, name: "Water")]
        let parsed = try roundTrip(routes: routes, waypoints: waypoints)
        XCTAssertEqual(parsed.routes.count, 2)
        XCTAssertEqual(parsed.routes.map(\.name), ["First", "Second"])
        XCTAssertEqual(parsed.waypoints.count, 1)
        XCTAssertEqual(parsed.waypoints[0].name, "Water")
        XCTAssertEqual(parsed.waypoints[0].lat, 9)
        XCTAssertEqual(parsed.waypoints[0].lon, 10)
    }

    func testWaypointElevationRoundTrip() throws {
        let waypoints = [Waypoint(lat: 9, lon: 10, name: "Camp", elevation: 2134.5)]
        let xml = GPXWriter.export(routes: [], waypoints: waypoints)
        XCTAssertTrue(xml.contains("<ele>2134.50</ele>"))
        let parsed = try parseGPX(xml)
        XCTAssertEqual(parsed.waypoints[0].elevation ?? 0, 2134.5, accuracy: 0.01)
    }

    func testMetadataName() throws {
        let routes = [Route(id: 1, name: "Track A", points: [RoutePoint(lat: 1, lon: 2), RoutePoint(lat: 3, lon: 4)], color: "#e11d48")]
        let xml = GPXWriter.export(routes: routes, waypoints: [], name: "Grand Loop")
        XCTAssertTrue(xml.contains("<metadata>\n    <name>Grand Loop</name>\n  </metadata>"))
    }

    func testMetadataFallbackToFirstRoute() throws {
        let routes = [Route(id: 1, name: "Maroon Bells", points: [RoutePoint(lat: 1, lon: 2), RoutePoint(lat: 3, lon: 4)], color: "#e11d48")]
        let xml = GPXWriter.export(routes: routes, waypoints: [])
        XCTAssertTrue(xml.contains("<name>Maroon Bells</name>"))
        let parsed = try parseGPX(xml)
        XCTAssertEqual(parsed.metadataName, "Maroon Bells")
    }

    func testMetadataRoundTrip() throws {
        let routes = [Route(id: 1, name: "Track A", points: [RoutePoint(lat: 1, lon: 2), RoutePoint(lat: 3, lon: 4)], color: "#e11d48")]
        let parsed = try roundTrip(routes: routes, waypoints: [], name: "Grand Loop")
        XCTAssertEqual(parsed.metadataName, "Grand Loop")
    }

    // parseGPX tests

    func testParseTrackWithElevations() throws {
        let sample = """
        <?xml version="1.0"?>
        <gpx version="1.1" creator="GPX Plotter" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Lake Loop</name></metadata>
          <trk><name>Track One</name><trkseg>
            <trkpt lat="39.55" lon="-107.32"><ele>1750.5</ele></trkpt>
            <trkpt lat="39.551" lon="-107.318"><ele>1800.1</ele></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let parsed = try parseGPX(sample)
        XCTAssertEqual(parsed.routes.count, 1)
        XCTAssertEqual(parsed.routes[0].name, "Track One")
        XCTAssertEqual(parsed.routes[0].points.count, 2)
        XCTAssertEqual(parsed.routes[0].points[0].elevation ?? 0, 1750.5, accuracy: 1e-6)
    }

    func testPrefersTrackNameOverMetadata() throws {
        let sample = """
        <?xml version="1.0"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Lake Loop</name></metadata>
          <trk><name>Track One</name><trkseg>
            <trkpt lat="39.55" lon="-107.32"/>
          </trkseg></trk>
        </gpx>
        """
        let parsed = try parseGPX(sample)
        XCTAssertEqual(parsed.routes[0].name, "Track One")
    }

    func testParseMultipleTracks() throws {
        let multi = """
        <?xml version="1.0"?>
        <gpx xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>A</name><trkseg><trkpt lat="1" lon="2"/><trkpt lat="3" lon="4"/></trkseg></trk>
          <trk><name>B</name><trkseg><trkpt lat="5" lon="6"/><trkpt lat="7" lon="8"/></trkseg></trk>
        </gpx>
        """
        let parsed = try parseGPX(multi)
        XCTAssertEqual(parsed.routes.map(\.name), ["A", "B"])
    }

    func testParseRoutesWhenNoTrack() throws {
        let rte = """
        <?xml version="1.0"?>
        <gpx xmlns="http://www.topografix.com/GPX/1/1"><rte><name>Road Trip</name>
          <rtept lat="1" lon="2"/><rtept lat="3" lon="4"><ele>5</ele></rtept></rte></gpx>
        """
        let parsed = try parseGPX(rte)
        XCTAssertEqual(parsed.routes.count, 1)
        XCTAssertEqual(parsed.routes[0].name, "Road Trip")
        XCTAssertEqual(parsed.routes[0].points.count, 2)
        XCTAssertEqual(parsed.routes[0].points[1].elevation, 5)
    }

    func testParseWaypoints() throws {
        let wps = """
        <?xml version="1.0"?>
        <gpx xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>T</name><trkseg><trkpt lat="1" lon="2"/><trkpt lat="3" lon="4"/></trkseg></trk>
          <wpt lat="9" lon="10"><name>Camp</name></wpt>
          <wpt lat="11" lon="12"/>
        </gpx>
        """
        let parsed = try parseGPX(wps)
        XCTAssertEqual(parsed.waypoints.count, 2)
        XCTAssertEqual(parsed.waypoints[0], Waypoint(lat: 9, lon: 10, name: "Camp"))
        XCTAssertEqual(parsed.waypoints[1].name, "Waypoint 2")
    }

    func testParseWaypointElevation() throws {
        let wps = """
        <?xml version="1.0"?>
        <gpx xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>T</name><trkseg><trkpt lat="1" lon="2"/><trkpt lat="3" lon="4"/></trkseg></trk>
          <wpt lat="9" lon="10"><name>Camp</name><ele>1234.5</ele></wpt>
        </gpx>
        """
        let parsed = try parseGPX(wps)
        XCTAssertEqual(parsed.waypoints[0].elevation ?? 0, 1234.5, accuracy: 1e-6)
    }

    func testThrowsOnNonXML() {
        XCTAssertThrowsError(try parseGPX("this is not xml"))
    }

    func testThrowsOnNoPointsOrWaypoints() {
        XCTAssertThrowsError(try parseGPX("<gpx xmlns=\"http://www.topografix.com/GPX/1/1\"></gpx>"))
    }
}