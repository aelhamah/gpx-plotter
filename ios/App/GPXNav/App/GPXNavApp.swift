import SwiftUI
import RouteKit

@main
struct GPXNavApp: App {
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var slopeServer = SlopeServerManager()
    @StateObject private var location = LocationController()

    init() {
        // Must happen before the first MLNMapView is created or MLNOfflineStorage
        // is used, since NSURLSession copies its configuration at init.
        MapNetworkIdentity.apply()
        print("[MapNetworkIdentity] allowlist this on the MapTiler key: \(MapNetworkIdentity.allowlistToken)")
        print("[MapNetworkIdentity] full User-Agent: \(MapNetworkIdentity.userAgent)")
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(workspace)
                .environmentObject(location)
                .task { slopeServer.start() }
        }
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var routes: [Route]
    @Published var waypoints: [Waypoint] = []
    @Published var selectedRouteId: Int? = nil
    @Published var unitSystem: UnitSystem = Units.defaultUnitSystem()
    @Published var mapStyle: MapStyle = .outdoor
    @Published var showHillshade = false
    @Published var showSlope = false
    @Published var showTerrain3D = false
    /// Set when the last import failed, so the library can show why.
    @Published var importError: String?
    /// Name of the GPX file the routes came from, when imported.
    @Published var documentName: String?

    private var nextRouteId: Int

    init() {
        if let restored = Self.loadPersisted() {
            routes = restored.routes
            waypoints = restored.waypoints
            selectedRouteId = restored.selectedRouteId
            if let system = restored.unitSystem { unitSystem = system }
            documentName = restored.documentName
            nextRouteId = restored.nextRouteId
        } else {
            // Seeded from web/public/demos so the map has something to show on a
            // fresh install. Replaced by whatever is imported next.
            let demo = DemoData.route
            routes = [demo]
            nextRouteId = demo.id + 1
        }
        // Terrain overlays normally start off and are toggled in Settings, but
        // `simctl launch` cannot tap, so `-showRelief` / `-showSlope` turn them
        // on for the M0 terrain check.
        let arguments = ProcessInfo.processInfo.arguments
        showHillshade = arguments.contains("-showRelief")
        showSlope = arguments.contains("-showSlope")
        showTerrain3D = arguments.contains("-terrain3D")

        // `-importGPX <name>` reads a GPX from Documents at launch, so the import
        // path can be checked without driving the document picker.
        if let index = arguments.firstIndex(of: "-importGPX"),
           arguments.count > index + 1 {
            let name = arguments[index + 1]
            let ok = importGPXFromDocuments(named: name)
            print("[Import] \(name) -> \(ok ? "ok" : "failed: \(importError ?? "unknown")")")
            print("[Import] routes=\(routes.count) points=\(routes.map(\.points.count))")
        }
    }

    // MARK: - GPX import

    /// Parse `text` and add its routes and waypoints to the workspace.
    ///
    /// Route ids are reassigned on the way in, because a GPX file carries no
    /// ids and two imports of the same file would otherwise collide.
    @discardableResult
    func importGPX(_ text: String, fileName: String?) -> Bool {
        importError = nil
        let parsed: ParsedGPX
        do {
            parsed = try parseGPX(text)
        } catch {
            importError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return false
        }

        guard !parsed.routes.isEmpty else {
            importError = GPXError.noData.localizedDescription
            return false
        }

        var imported: [Route] = []
        for route in parsed.routes {
            var copy = route
            copy.id = nextRouteId
            nextRouteId += 1
            copy.color = RoutePalette.color(forId: copy.id)
            imported.append(copy)
        }
        routes.append(contentsOf: imported)
        waypoints.append(contentsOf: parsed.waypoints)
        if let name = fileName { documentName = name }
        // Open what was just imported.
        if let first = imported.first { selectedRouteId = first.id }
        save()
        return true
    }

    /// Import a GPX from the app's Documents directory, for `-importGPX <name>`.
    ///
    /// `simctl launch` cannot drive the document picker, so this makes the
    /// import path verifiable on the simulator.
    @discardableResult
    func importGPXFromDocuments(named name: String) -> Bool {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let url = documents?.appendingPathComponent(name) else { return false }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importError = "Could not read \(name) from Documents."
            return false
        }
        return importGPX(text, fileName: name)
    }

    // MARK: - Persistence

    private static var storeURL: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        // iOS does not create Application Support for us, and the first save
        // would otherwise fail with "the folder doesn't exist".
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("workspace.json")
    }

    private static func loadPersisted() -> PersistedWorkspace? {
        guard let url = storeURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? WorkspaceCodec.decode(data)
    }

    func save() {
        guard let url = Self.storeURL else { return }
        let workspace = PersistedWorkspace(
            routes: routes,
            waypoints: waypoints,
            nextRouteId: nextRouteId,
            documentName: documentName,
            selectedRouteId: selectedRouteId,
            unitSystem: unitSystem
        )
        do {
            try WorkspaceCodec.encode(workspace).write(to: url, options: .atomic)
        } catch {
            print("Workspace save failed: \(error)")
        }
    }

    /// Wipe the library and the saved file, e.g. from Settings.
    func clearAll() {
        routes = []
        waypoints = []
        selectedRouteId = nil
        documentName = nil
        nextRouteId = 1
        if let url = Self.storeURL { try? FileManager.default.removeItem(at: url) }
    }
}

/// Route colors, ported from `web/src/colors.ts`.
enum RoutePalette {
    private static let cycle = [
        "#e11d48", "#2563eb", "#16a34a", "#d97706",
        "#9333ea", "#0f766e", "#dc2626"
    ]

    /// Deterministic pick for a 1-based route id, wrapping like the web app.
    static func color(forId id: Int) -> String {
        cycle[(((id - 1) % cycle.count) + cycle.count) % cycle.count]
    }
}

/// Keeps the loopback slope server alive for the app's lifetime.
@MainActor
final class SlopeServerManager: ObservableObject {
    private var server: SlopeServer?

    func start() {
        guard server == nil else { return }
        do {
            let server = try SlopeServer(
                terrainStore: TerrainTileStore(config: AppConfig.terrainConfig),
                styleBuilder: StyleBuilder(config: AppConfig.terrainTileConfig),
                port: AppConfig.slopePort
            )
            server.start()
            self.server = server
        } catch {
            print("Slope server failed to start: \(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }
}
