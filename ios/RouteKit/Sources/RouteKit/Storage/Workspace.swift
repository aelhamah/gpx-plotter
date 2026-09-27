import Foundation

/// View/camera state persisted with the workspace.
public struct WorkspaceView: Equatable, Sendable, Codable {
    public var center: Coordinate
    public var zoom: Double
    public var bearing: Double
    public var pitch: Double

    public init(center: Coordinate, zoom: Double, bearing: Double, pitch: Double) {
        self.center = center
        self.zoom = zoom
        self.bearing = bearing
        self.pitch = pitch
    }
}

/// Everything that is kept across reloads for the current map/workspace.
public struct PersistedWorkspace: Equatable, Sendable, Codable {
    public var version: Int
    public var routes: [Route]
    public var waypoints: [Waypoint]
    public var nextRouteId: Int
    public var documentName: String?
    public var selectedRouteId: Int?
    public var unitSystem: UnitSystem?
    public var view: WorkspaceView?

    public init(
        version: Int = 1,
        routes: [Route] = [],
        waypoints: [Waypoint] = [],
        nextRouteId: Int = 1,
        documentName: String? = nil,
        selectedRouteId: Int? = nil,
        unitSystem: UnitSystem? = nil,
        view: WorkspaceView? = nil
    ) {
        self.version = version
        self.routes = routes
        self.waypoints = waypoints
        self.nextRouteId = nextRouteId
        self.documentName = documentName
        self.selectedRouteId = selectedRouteId
        self.unitSystem = unitSystem
        self.view = view
    }
}

public let storageKey = "gpx-plotter:workspace"
public let storageVersion = 1

/// Codec for versioned workspace JSON with tolerant decoding (matches web behavior).
public enum WorkspaceCodec {
    /// Encode a workspace to JSON data.
    public static func encode(_ workspace: PersistedWorkspace) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(workspace)
    }

    /// Decode a workspace from JSON data, applying version checks and defaults.
    public static func decode(_ data: Data) throws -> PersistedWorkspace? {
        let decoder = JSONDecoder()
        let raw = try decoder.decode(RawWorkspace.self, from: data)
        guard raw.version == storageVersion else { return nil }
        guard let routes = raw.routes, let waypoints = raw.waypoints else { return nil }

        let nextRouteId = (raw.nextRouteId ?? 0) > 0 ? raw.nextRouteId! : 1
        let documentName = raw.documentName
        let selectedRouteId: Int? = raw.selectedRouteId
        let unitSystem: UnitSystem? = raw.unitSystem
        let view: WorkspaceView? = raw.view.map { v in
            WorkspaceView(center: v.center, zoom: v.zoom, bearing: v.bearing, pitch: v.pitch)
        }

        return PersistedWorkspace(
            version: storageVersion,
            routes: routes,
            waypoints: waypoints,
            nextRouteId: nextRouteId,
            documentName: documentName,
            selectedRouteId: selectedRouteId,
            unitSystem: unitSystem,
            view: view
        )
    }

    /// Internal raw type for tolerant decoding.
    private struct RawWorkspace: Codable {
        var version: Int
        var routes: [Route]?
        var waypoints: [Waypoint]?
        var nextRouteId: Int?
        var documentName: String?
        var selectedRouteId: Int?
        var unitSystem: UnitSystem?
        var view: RawWorkspaceView?
    }

    private struct RawWorkspaceView: Codable {
        var center: Coordinate
        var zoom: Double
        var bearing: Double
        var pitch: Double
    }
}