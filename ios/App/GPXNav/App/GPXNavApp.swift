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
    @Published var maps: [MapDocument] = []
    @Published var selectedMapId: Int? = nil

    @Published var routes: [Route] = []
    @Published var waypoints: [Waypoint] = []
    @Published var draft: Route? = nil
    @Published var selectedRouteId: Int? = nil
    @Published var nextRouteId: Int = 1

    @Published var unitSystem: UnitSystem = Units.defaultUnitSystem()
    @Published var mapStyle: MapStyle = ProcessInfo.processInfo.arguments.contains("-satellite")
        ? .satellite
        : .outdoor
    @Published var showHillshade = false
    @Published var showSlope = false
    @Published var showTerrain3D = false
    @Published var fillsMissingElevation = false

    @Published var importError: String?
    @Published var documentName: String?

    private var nextMapId = 1

    init() {
        if let url = Self.storeURL, let data = try? Data(contentsOf: url),
           let loaded = try? LibraryCodec.decode(data) {
            maps = loaded.maps
            selectedMapId = loaded.selectedMapId
            nextMapId = (maps.map(\.id).max() ?? 0) + 1
            if maps.isEmpty {
                seedDemoMap()
            }
            hydrateSelectedMap()
        } else {
            seedDemoMap()
            hydrateSelectedMap()
        }

        let arguments = ProcessInfo.processInfo.arguments
        showHillshade = arguments.contains("-showRelief")
        showSlope = arguments.contains("-showSlope")
        showTerrain3D = arguments.contains("-terrain3D")
        fillsMissingElevation = arguments.contains("-fillElevation")

        if let index = arguments.firstIndex(of: "-importGPX"),
           arguments.count > index + 1 {
            let name = arguments[index + 1]
            let ok = importGPXFromDocuments(named: name)
            print("[Import] \(name) -> \(ok ? "ok" : "failed: \(importError ?? "unknown")")")
            print("[Import] routes=\(routes.count) points=\(routes.map(\.points.count))")
        }
    }

    // MARK: - Current map access

    var selectedMap: MapDocument? {
        guard let selectedMapId else { return nil }
        return maps.first { $0.id == selectedMapId }
    }

    func selectedMapIndex() -> Int? {
        guard let selectedMapId else { return nil }
        return maps.firstIndex { $0.id == selectedMapId }
    }

    private func seedDemoMap() {
        let demo = DemoData.route
        var map = MapDocument(id: nextMapId, name: "Demo route")
        map.routes = [demo]
        map.nextRouteId = demo.id + 1
        nextMapId += 1
        maps = [map]
        selectedMapId = map.id
    }

    private func hydrateSelectedMap() {
        guard let map = selectedMap else {
            routes = []
            waypoints = []
            draft = nil
            selectedRouteId = nil
            documentName = nil
            nextRouteId = 1
            return
        }
        routes = map.routes
        waypoints = map.waypoints
        draft = map.draft
        selectedRouteId = map.selectedRouteId
        documentName = map.name
        nextRouteId = map.nextRouteId
    }

    func syncSelectedMap() {
        guard let index = selectedMapIndex() else { return }
        var map = maps[index]
        map.routes = routes
        map.waypoints = waypoints
        map.draft = draft
        map.selectedRouteId = selectedRouteId
        if let name = documentName { map.name = name }
        map.nextRouteId = nextRouteId
        maps[index] = map
        maps = maps
    }

    func selectMap(_ id: Int) {
        syncSelectedMap()
        selectedMapId = id
        hydrateSelectedMap()
    }

    func allocateMapId() -> Int {
        let id = nextMapId
        nextMapId += 1
        return id
    }

    func allocateRouteId() -> Int {
        let id = nextRouteId
        nextRouteId += 1
        return id
    }

    func newMap() -> MapDocument {
        syncSelectedMap()
        let map = MapDocument(id: allocateMapId(), name: "New Map", nextRouteId: 1)
        maps.append(map)
        selectedMapId = map.id
        hydrateSelectedMap()
        return map
    }

    // MARK: - Import (selected map)

    @discardableResult
    func importGPX(_ text: String, fileName: String?) -> Bool {
        importError = nil
        if selectedMap == nil {
            _ = newMap()
        }
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
            copy.id = allocateRouteId()
            copy.color = RoutePalette.color(forId: copy.id)
            imported.append(copy)
        }
        routes.append(contentsOf: imported)
        waypoints.append(contentsOf: parsed.waypoints)
        if let name = fileName { documentName = name }
        if let first = imported.first { selectedRouteId = first.id }
        save()
        return true
    }

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
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("workspace.json")
    }

    func save() {
        syncSelectedMap()
        guard let url = Self.storeURL else { return }
        let library = PersistedLibrary(
            version: libraryStorageVersion,
            maps: maps,
            selectedMapId: selectedMapId
        )
        do {
            let data = try LibraryCodec.encode(library)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Workspace save failed: \(error)")
        }
    }

    func clearAll() {
        maps = []
        selectedMapId = nil
        nextMapId = 1
        hydrateSelectedMap()
        if let url = Self.storeURL { try? FileManager.default.removeItem(at: url) }
    }
}

/// Route colors, ported from `web/src/colors.ts`.
enum RoutePalette {
    private static let cycle = [
        "#e11d48", "#2563eb", "#16a34a", "#d97706",
        "#9333ea", "#0f766e", "#dc2626"
    ]

    static func color(forId id: Int) -> String {
        cycle[(((id - 1) % cycle.count) + cycle.count) % cycle.count]
    }
}

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
