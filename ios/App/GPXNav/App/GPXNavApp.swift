import SwiftUI
import RouteKit

@main
struct GPXNavApp: App {
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var services = AppServices()
    @StateObject private var location = LocationController()

    init() {
        // Must happen before the first MLNMapView is created, since NSURLSession
        // copies its configuration at init.
        MapNetworkIdentity.apply()
        print("[MapNetworkIdentity] allowlist this on the MapTiler key: \(MapNetworkIdentity.allowlistToken)")
        print("[MapNetworkIdentity] full User-Agent: \(MapNetworkIdentity.userAgent)")
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(workspace)
                .environmentObject(location)
                .environmentObject(services)
                .task {
                    // The offline manager needs the library to turn a pack's record
                    // back into the tiles it covers when one is deleted. Both are
                    // owned here, so this is where the two meet.
                    services.offline.workspace = workspace
                    services.start()
                }
        }
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var routes: [Route]
    @Published var waypoints: [Waypoint] = []
    @Published var selectedRouteId: Int? = nil
    @Published var unitSystem: UnitSystem = Units.defaultUnitSystem()
    @Published var mapStyle: MapStyle = ProcessInfo.processInfo.arguments.contains("-satellite")
        ? .satellite
        : .outdoor
    @Published var showHillshade = false
    @Published var showSlope = false
    @Published var showTerrain3D = false
    /// Whether to ask the terrain model for the elevations a track does not
    /// carry, off by default (#72).
    ///
    /// Off means the profile shows the elevations the file actually recorded,
    /// joined by straight lines between them, and nothing else. On means the
    /// gaps between those are filled from MapTiler's terrain model, which costs
    /// a network round trip per gap and is the only reason to have a key at all.
    ///
    /// Neither setting overwrites an elevation the file provided. That is not a
    /// promise this flag makes and can break -- it is what the fill has always
    /// done, and `ElevationFillTests` pins it -- so turning this on cannot
    /// corrupt a track that was recorded properly. The reason it is opt-in at
    /// all is that the terrain model and a hand-drawn route disagree by hundreds
    /// of metres, and the user is better placed than the app to decide whose
    /// answer to show.
    @Published var fillsMissingElevation = false
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
        // on for the M0 terrain check. `-satellite` does the same for the base
        // layer, which is how the raster tileset's half of the offline cache gets
        // exercised.
        let arguments = ProcessInfo.processInfo.arguments
        showHillshade = arguments.contains("-showRelief")
        showSlope = arguments.contains("-showSlope")
        showTerrain3D = arguments.contains("-terrain3D")
        // `-fillElevation` opts a capture or a device check into the terrain
        // fill, which is off for everyone else (#72).
        fillsMissingElevation = arguments.contains("-fillElevation")

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

/// The app's long-lived services: the loopback server, the tile cache it serves
/// from, the style builder both it and the offline manager need, and the offline
/// manager itself.
///
/// These are one object because they are genuinely one thing: the loopback
/// server repoints the basemap at the cache, so a tile only reaches the disk
/// once, and the offline manager is prefetching into the same cache the map is
/// already warming. Handing each view its own instance would mean the map and
/// the download filled two different caches.
@MainActor
final class AppServices: ObservableObject {
    let cache = TileCache()
    let styleBuilder: StyleBuilder
    let offline: OfflinePackManager

    private var server: SlopeServer?

    /// The loopback listener has bound, so a request to it will be answered
    /// rather than refused.
    ///
    /// The map views wait on this before building themselves at all, because
    /// MapLibre asks for `style.json` the instant the view exists and never
    /// repeats a refused ask — and `start()` cannot promise the bind has
    /// landed, only that it has been requested. See `SlopeServer.onReady`.
    @Published private(set) var serverReady = false

    init() {
        let config = AppConfig.terrainTileConfig
        styleBuilder = StyleBuilder(config: config)
        offline = OfflinePackManager(cache: cache, styleBuilder: styleBuilder)
        // Started here rather than from the scene's `.task`, which runs *after*
        // the first view has rendered — and the first view may be the map.
        //
        // Starting early shrinks the race but does not close it: `NWListener`
        // binds asynchronously, so `start()` returning does not mean the port
        // accepts yet. Inside that window MapLibre's first `style.json` ask is
        // refused and never repeated, while its own resource cache serves back
        // a style built in an earlier launch — one whose `StyleBuilder` is
        // gone — so `upstreamTemplates` stays empty here, every tile answers
        // 404 "no basemap", and the map renders as a flat colour with the
        // route floating on it. The views hold the map until `serverReady`.
        //
        // `start()` is idempotent, so the scene's call is harmless.
        start()
    }

    /// Bring up the loopback server. Everything else is lazy.
    func start() {
        guard server == nil else { return }
        let server = SlopeServer(
            styleBuilder: styleBuilder,
            tileCache: cache,
            port: AppConfig.slopePort
        )
        // The listener reports on its own queue; hop, because
        // `serverReady` drives view updates.
        server.onReady = { [weak self] in
            Task { @MainActor in
                self?.serverReady = true
            }
        }
        server.start()
        self.server = server
    }

    func stop() {
        server?.stop()
        server = nil
        serverReady = false
    }
}
