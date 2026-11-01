import XCTest
@testable import RouteKit

final class LibraryStorageTests: XCTestCase {
    func testLibraryCodecRoundTripsMaps() throws {
        let route = Route(id: 5, name: "Route 5", points: [], color: "#2563eb")
        let map = MapDocument(id: 2, name: "Trip", routes: [route], waypoints: [], nextRouteId: 6)
        let library = PersistedLibrary(maps: [map], selectedMapId: 2)

        let data = try LibraryCodec.encode(library)
        let decoded = try XCTUnwrap(LibraryCodec.decode(data))

        XCTAssertEqual(decoded.version, libraryStorageVersion)
        XCTAssertEqual(decoded.selectedMapId, 2)
        XCTAssertEqual(decoded.maps.count, 1)
        XCTAssertEqual(decoded.maps[0], map)
    }

    func testLibraryCodecMigratesLegacyWorkspace() throws {
        let route = Route(id: 9, name: "Imported", points: [], color: "#dc2626")
        let old = PersistedWorkspace(
            version: storageVersion,
            routes: [route],
            waypoints: [],
            draft: route,
            nextRouteId: 10,
            documentName: "legacy.gpx",
            selectedRouteId: 9,
            unitSystem: .metric
        )

        let data = try WorkspaceCodec.encode(old)
        let decoded = try XCTUnwrap(LibraryCodec.decode(data))

        XCTAssertEqual(decoded.version, libraryStorageVersion)
        XCTAssertEqual(decoded.maps.count, 1)
        XCTAssertEqual(decoded.maps[0].name, "legacy.gpx")
        XCTAssertEqual(decoded.maps[0].routes, old.routes)
        XCTAssertEqual(decoded.maps[0].draft, old.draft)
        XCTAssertEqual(decoded.maps[0].selectedRouteId, 9)
        XCTAssertEqual(decoded.maps[0].nextRouteId, 10)
    }
}
