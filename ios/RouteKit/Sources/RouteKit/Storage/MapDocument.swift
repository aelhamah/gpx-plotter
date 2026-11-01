import Foundation

/// One GPX document in the map library.
///
/// A document may contain several routes and waypoints, plus an unfinished
/// route being drawn in the editor. That is its identity on disk: a library
/// item is a whole GPX file, not one polyline.
public struct MapDocument: Hashable, Equatable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    public var routes: [Route]
    public var waypoints: [Waypoint]
    public var draft: Route?
    public var selectedRouteId: Int?
    public var nextRouteId: Int

    public init(
        id: Int,
        name: String = "Untitled Map",
        routes: [Route] = [],
        waypoints: [Waypoint] = [],
        draft: Route? = nil,
        selectedRouteId: Int? = nil,
        nextRouteId: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.routes = routes
        self.waypoints = waypoints
        self.draft = draft
        self.selectedRouteId = selectedRouteId
        self.nextRouteId = nextRouteId ?? MapDocument.derivedNextRouteId(for: routes)
    }

    public var hasFinishedRoutes: Bool {
        !routes.isEmpty
    }

    public mutating func allocateRouteId() -> Int {
        let id = nextRouteId
        nextRouteId += 1
        return id
    }

    private static func derivedNextRouteId(for routes: [Route]) -> Int {
        (routes.map(\.id).max() ?? 0) + 1
    }
}

extension MapDocument {
    /// Convert the legacy one-workspace model into one document for migration.
    public init(migrating workspace: PersistedWorkspace, id: Int = 1) {
        self.init(
            id: id,
            name: workspace.documentName ?? "Untitled Map",
            routes: workspace.routes,
            waypoints: workspace.waypoints,
            draft: workspace.draft,
            selectedRouteId: workspace.selectedRouteId,
            nextRouteId: workspace.nextRouteId
        )
    }
}

/// Everything kept across runs for the whole map library.
public struct PersistedLibrary: Equatable, Sendable, Codable {
    public var version: Int
    public var maps: [MapDocument]
    public var selectedMapId: Int?

    public init(
        version: Int = libraryStorageVersion,
        maps: [MapDocument] = [],
        selectedMapId: Int? = nil
    ) {
        self.version = version
        self.maps = maps
        self.selectedMapId = selectedMapId
    }
}
