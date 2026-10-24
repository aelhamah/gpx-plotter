import SwiftUI
import RouteKit

/// Create a route: tap the map to draw it, with trail snapping, waypoints, undo/redo.
struct CreateView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var services: AppServices
    @StateObject private var controller = CreateDraftController()

    @State private var isSearching = false
    @State private var mergeSheet = false

    private var placeholderRoute: Route {
        Route(id: 0, name: "", points: [], color: "#2563eb")
    }

    var body: some View {
        ZStack {
            MapView(
                route: placeholderRoute,
                draftRoute: controller.draft,
                onMapTap: { coordinate, zoom in
                    Task { await controller.handleMapTap(workspace: workspace, coordinate: coordinate, zoom: zoom) }
                },
                onDraftVertexMoved: { index, coordinate in
                    controller.moveDraftVertex(workspace: workspace, index: index, coordinate: coordinate)
                },
                onDraftVertexEnded: {
                    controller.endDraftVertexDrag(workspace: workspace)
                }
            )
            .ignoresSafeArea()

            VStack {
                // Top bar
                HStack(spacing: 12) {
                    Button {
                        controller.undo(workspace: workspace)
                    } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(controller.historyEmpty)
                    Button {
                        controller.redo(workspace: workspace)
                    } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(controller.futureEmpty)

                    Spacer()

                    Toggle(isOn: $controller.snappingEnabled) {
                        Text("Snap")
                    }
                    .toggleStyle(.button)

                    Button {
                        controller.toggleMergePick(workspace: workspace)
                    } label: { Image(systemName: "arrow.triangle.merge") }
                    .foregroundStyle(controller.mergePickMode ? Color.accentColor : .primary)

                    Button("Finish", systemImage: "checkmark.circle.fill") {
                        controller.finish(workspace: workspace)
                    }
                    .disabled(!(controller.draft?.points.count ?? 0 >= 2) || !controller.isDrawing)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
                .padding(.top, 60)

                Spacer()

                if controller.waypointMode {
                    Text(controller.waypointHint)
                        .font(.caption)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                }

                if controller.isDrawing {
                    drawBar
                } else if controller.mergePickMode {
                    VStack(spacing: 8) {
                        Text(controller.mergePick == nil ? "Pick first route to merge" : "Pick second route")
                            .font(.caption)
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(workspace.routes) { route in
                                    Button(route.name) {
                                        controller.selectMergeRoute(workspace: workspace, route: route)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(controller.mergePick?.id == route.id ? .accentColor : nil)
                                }
                            }
                        }
                        Button("Cancel merge") { controller.toggleMergePick(workspace: workspace) }
                            .buttonStyle(.bordered)
                    }
                    .padding(.bottom, 24)
                } else {
                    HStack(spacing: 12) {
                        Button("Draw route", systemImage: "square.and.pencil") {
                            controller.startDrawing(workspace: workspace)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Add waypoint", systemImage: "mappin") {
                            controller.setWaypointMode(true, workspace: workspace)
                        }
                        .buttonStyle(.bordered)

                        Button("New route", systemImage: "plus") {
                            controller.newRouteAndDraw(workspace: workspace)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.bottom, 24)
                }
            }

            if controller.mergePickMode {
                VStack {
                    Spacer()
                    Text("Tap a route to merge (not yet wired on iOS)")
                        .padding()
                        .background(.regularMaterial)
                        .cornerRadius(12)
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $isSearching) {
            SearchView(proximity: nil) { result in
                if controller.waypointMode {
                    // search result becomes waypoint via controller
                } else {
                    controller.addWaypointFromSearch(workspace: workspace, result: result)
                }
            }
        }
        .task {
            controller.snapEngine = SnapEngine(
                httpClient: DefaultHTTPClient(userAgent: MapNetworkIdentity.userAgent),
                config: AppConfig.snapConfig,
                diskCache: services.cache
            )
            if controller.draft == nil, let d = workspace.draft {
                controller.draft = d
                controller.isDrawing = true
                controller.updateStatus()
            }
            if ProcessInfo.processInfo.arguments.contains("-openSearch") {
                isSearching = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToCreate)) { _ in
            if let d = workspace.draft {
                controller.draft = d
                controller.isDrawing = true
                controller.updateStatus()
            }
        }
    }

    private var drawBar: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: controller.draft?.color ?? "#2563eb")).frame(width: 10, height: 10)
            Text(controller.statusText)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Text("\(controller.draft?.points.count ?? 0) pts")
                .font(.caption.monospacedDigit())
            Button("Finish") { controller.finish(workspace: workspace) }
                .disabled((controller.draft?.points.count ?? 0) < 2)
            Button("Cancel") { controller.stopDrawing() }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 24)
    }
}

@MainActor
final class CreateDraftController: ObservableObject {
    @Published var draft: Route?
    @Published var isDrawing = false
    @Published var waypointMode = false
    @Published var snappingEnabled = SNAP_ENABLED_BY_DEFAULT
    @Published var mergePickMode = false
    @Published var mergePick: Route?
    @Published var statusText = ""
    @Published private(set) var history: [Snapshot] = []
    @Published private(set) var future: [Snapshot] = []

    var snapEngine: SnapEngine = SnapEngine(
        httpClient: DefaultHTTPClient(),
        config: nil,
        diskCache: nil
    )

    struct Snapshot {
        let routes: [Route]
        let waypoints: [Waypoint]
        let draft: Route?
    }

    var historyEmpty: Bool { history.isEmpty }
    var futureEmpty: Bool { future.isEmpty }

    var waypointHint: String { waypointHintText(snappingEnabled: snappingEnabled) }

    func commitSnapshot(workspace: WorkspaceStore) {
        history.append(Snapshot(routes: workspace.routes, waypoints: workspace.waypoints, draft: draft))
        if history.count > 50 { history.removeFirst() }
        future.removeAll()
    }

    func undo(workspace: WorkspaceStore) {
        guard let previous = history.popLast() else { return }
        future.append(Snapshot(routes: workspace.routes, waypoints: workspace.waypoints, draft: draft))
        workspace.routes = previous.routes
        workspace.waypoints = previous.waypoints
        draft = previous.draft
        workspace.save()
        updateStatus()
    }

    func redo(workspace: WorkspaceStore) {
        guard let next = future.popLast() else { return }
        history.append(Snapshot(routes: workspace.routes, waypoints: workspace.waypoints, draft: draft))
        workspace.routes = next.routes
        workspace.waypoints = next.waypoints
        draft = next.draft
        workspace.save()
        updateStatus()
    }

    func updateStatus() {
        statusText = drawStatusText(pointCount: draft?.points.count ?? 0, snappingEnabled: snappingEnabled)
    }

    func startDrawing(workspace: WorkspaceStore) {
        if mergePickMode { exitMergePick() }
        if waypointMode { setWaypointMode(false, workspace: workspace) }
        if draft == nil {
            commitSnapshot(workspace: workspace)
            let id = workspace.allocateRouteId()
            draft = Route(id: id, name: "Route \(id)", points: [], color: RoutePalette.color(forId: id))
        }
        isDrawing = true
        updateStatus()
    }

    func stopDrawing() {
        isDrawing = false
        updateStatus()
    }

    func newRouteAndDraw(workspace: WorkspaceStore) {
        commitSnapshot(workspace: workspace)
        let id = workspace.allocateRouteId()
        draft = Route(id: id, name: "Route \(id)", points: [], color: RoutePalette.color(forId: id))
        isDrawing = true
        updateStatus()
    }

    func finish(workspace: WorkspaceStore) {
        guard isDrawing, var d = draft, d.points.count >= 2 else {
            stopDrawing()
            return
        }
        if d.points.count >= 2 {
            let a = d.points[d.points.count - 1]
            let b = d.points[d.points.count - 2]
            if abs(a.lat - b.lat) < 1e-6 && abs(a.lon - b.lon) < 1e-6 {
                d.points.removeLast()
            }
        }
        if let idx = workspace.routes.firstIndex(where: { $0.id == d.id }) {
            workspace.routes[idx] = d
        } else {
            workspace.routes.append(d)
        }
        workspace.selectedRouteId = d.id
        workspace.draft = nil
        draft = nil
        isDrawing = false
        workspace.save()
        updateStatus()
    }

    func setWaypointMode(_ on: Bool, workspace: WorkspaceStore) {
        waypointMode = on
        if on {
            if mergePickMode { exitMergePick() }
            stopDrawing()
        }
    }

    func toggleMergePick(workspace: WorkspaceStore) {
        mergePickMode.toggle()
        if mergePickMode {
            if waypointMode { setWaypointMode(false, workspace: workspace) }
            stopDrawing()
            mergePick = nil
        } else {
            mergePick = nil
        }
    }

    func exitMergePick() {
        mergePickMode = false
        mergePick = nil
    }

    func handleMapTap(workspace: WorkspaceStore, coordinate: Coordinate, zoom: Double) async {
        if waypointMode {
            await addWaypoint(workspace: workspace, coordinate: coordinate, zoom: zoom)
            return
        }
        if isDrawing {
            await addRoutePoint(workspace: workspace, coordinate: coordinate, zoom: zoom)
            return
        }
        // merge picking not implemented
    }

    func addRoutePoint(workspace: WorkspaceStore, coordinate: Coordinate, zoom: Double) async {
        guard isDrawing, var d = draft else { return }
        commitSnapshot(workspace: workspace)
        d.points.append(RoutePoint(lat: coordinate.lat, lon: coordinate.lon))
        draft = d
        workspace.save()
        updateStatus()
        await snapRoutePointToTrail(workspace: workspace, raw: coordinate, zoom: zoom)
    }

    private func snapRoutePointToTrail(workspace: WorkspaceStore, raw: Coordinate, zoom: Double) async {
        guard snappingEnabled, let d0 = draft else { return }
        let index = d0.points.count - 1
        guard index >= 0 else { return }
        let previous = index > 0 ? d0.points[index - 1] : nil
        let snapZoom = SnapTiles.snapZoom(for: zoom)
        let nearNew = await snapEngine.trailsNearPoint(lng: raw.lon, lat: raw.lat, zoom: snapZoom)
        let nearPrev: SnapEngine.TrailQuery? = previous != nil
            ? await snapEngine.trailsNearPoint(lng: previous!.lon, lat: previous!.lat, zoom: snapZoom)
            : nil
        var lines = nearNew.lines
        if let nearPrev { lines.append(contentsOf: nearPrev.lines) }
        lines = TrailNetwork.dedupeTrailLines(lines)
        guard let match = nearestLine(raw, lines, TRAIL_SNAP_METERS) else { return }
        guard var d = draft, d.points.count > index else { return }
        let current = d.points[index]
        guard current.lon == raw.lon && current.lat == raw.lat else { return }

        var inserted = 0
        if let previous {
            let interior = TrailNetwork.trailVerticesBetween(
                lines,
                from: Coordinate(lat: previous.lat, lon: previous.lon),
                to: match.result.point,
                radiusMeters: TRAIL_SNAP_METERS
            )
            if !interior.isEmpty {
                d.points.insert(contentsOf: interior.map { RoutePoint(lat: $0.lat, lon: $0.lon) }, at: index)
                inserted = interior.count
            }
        }

        if inserted > 0 {
            let ci = index + inserted
            if ci < d.points.count {
                d.points[ci].lat = match.result.point.lat
                d.points[ci].lon = match.result.point.lon
            }
        } else {
            d.points[index].lat = match.result.point.lat
            d.points[index].lon = match.result.point.lon
        }
        draft = d
        workspace.save()
        updateStatus()
    }

    func addWaypoint(workspace: WorkspaceStore, coordinate: Coordinate, zoom: Double) async {
        guard waypointMode else { return }
        commitSnapshot(workspace: workspace)
        let index = workspace.waypoints.count
        workspace.waypoints.append(Waypoint(lat: coordinate.lat, lon: coordinate.lon, name: "Waypoint \(index + 1)"))
        waypointMode = false
        workspace.save()
        await snapWaypointToPeak(workspace: workspace, index: index, raw: coordinate, zoom: zoom)
    }

    func selectMergeRoute(workspace: WorkspaceStore, route: Route) {
        guard mergePickMode else { return }
        if mergePick == nil {
            mergePick = route
        } else if mergePick!.id != route.id {
            performMerge(workspace: workspace, first: mergePick!, second: route)
        }
    }

    private func performMerge(workspace: WorkspaceStore, first: Route, second: Route) {
        commitSnapshot(workspace: workspace)
        let id = workspace.allocateRouteId()
        let merged = Route(
            id: id,
            name: "\(first.name) + \(second.name)",
            points: mergeRoutePoints(first.points, second.points),
            color: RoutePalette.color(forId: id)
        )
        workspace.routes.append(merged)
        mergePickMode = false
        mergePick = nil
        workspace.save()
        updateStatus()
    }

    private func mergeRoutePoints(_ a: [RoutePoint], _ b: [RoutePoint], overlapMeters: Double = 10) -> [RoutePoint] {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        // orient
        let aStart = a[0], aEnd = a[a.count-1]
        let bStart = b[0], bEnd = b[b.count-1]
        let aRev = Array(a.reversed())
        let bRev = Array(b.reversed())
        struct Opt { let first:[RoutePoint]; let second:[RoutePoint]; let gap:Double }
        let options: [Opt] = [
            Opt(first: a, second: b, gap: Haversine.meters(from: aEnd.coordinate, to: bStart.coordinate)),
            Opt(first: a, second: bRev, gap: Haversine.meters(from: aEnd.coordinate, to: bEnd.coordinate)),
            Opt(first: aRev, second: b, gap: Haversine.meters(from: aStart.coordinate, to: bStart.coordinate)),
            Opt(first: aRev, second: bRev, gap: Haversine.meters(from: aStart.coordinate, to: bEnd.coordinate)),
        ]
        let chosen = options.min(by: { $0.gap < $1.gap })!
        let first = chosen.first
        let second = chosen.second
        // trim duplicated head
        func unitDir(_ pts: [RoutePoint]) -> (Double,Double)? {
            guard pts.count >= 2 else { return nil }
            let a = pts[pts.count-2], b = pts[pts.count-1]
            let dx = b.lon - a.lon, dy = b.lat - a.lat
            let len = hypot(dx,dy)
            return len < 1e-12 ? nil : (dx/len, dy/len)
        }
        // For trim, need tail dir of first (last two) and head dir of second (first two)
        let tailDir: (Double,Double)? = {
            guard first.count >= 2 else { return nil }
            let a = first[first.count-2], b = first[first.count-1]
            let dx = b.lon - a.lon, dy = b.lat - a.lat
            let len = hypot(dx,dy)
            return len < 1e-12 ? nil : (dx/len, dy/len)
        }()
        let headDir: (Double,Double)? = {
            guard second.count >= 2 else { return nil }
            let a = second[0], b = second[1]
            let dx = b.lon - a.lon, dy = b.lat - a.lat
            let len = hypot(dx,dy)
            return len < 1e-12 ? nil : (dx/len, dy/len)
        }()
        var trim = 0
        if let td = tailDir, let hd = headDir {
            let dot = td.0*hd.0 + td.1*hd.1
            if dot > 0 {
                var joint = first.count - 1
                while trim < second.count - 1 && joint - trim > 0 {
                    if Haversine.meters(from: first[joint-trim].coordinate, to: second[trim].coordinate) > overlapMeters + 1e-6 { break }
                    trim += 1
                }
            }
        }
        if trim == 0 { return first + second }
        return first + Array(second.dropFirst(trim))
    }

    private var isDraggingVertex = false

    func moveDraftVertex(workspace: WorkspaceStore, index: Int, coordinate: Coordinate) {
        if !isDraggingVertex {
            commitSnapshot(workspace: workspace)
            isDraggingVertex = true
        }
        guard var d = draft, d.points.indices.contains(index) else { return }
        d.points[index].lat = coordinate.lat
        d.points[index].lon = coordinate.lon
        draft = d
    }

    func endDraftVertexDrag(workspace: WorkspaceStore) {
        guard isDraggingVertex else { return }
        isDraggingVertex = false
        workspace.save()
        updateStatus()
    }

    func addWaypointFromSearch(workspace: WorkspaceStore, result: GeocodeResult) {
        workspace.waypoints.append(Waypoint(lat: result.center.lat, lon: result.center.lon, name: result.name, elevation: result.elevation))
        workspace.save()
    }

    private func snapWaypointToPeak(workspace: WorkspaceStore, index: Int, raw: Coordinate, zoom: Double) async {
        guard snappingEnabled else { return }
        let peaks = await snapEngine.peaksNearPoint(lng: raw.lon, lat: raw.lat, zoom: SnapTiles.snapZoom(for: zoom))
        guard !peaks.peaks.isEmpty else { return }
        let lines = peaks.peaks.map { [$0.center] }
        guard let match = nearestSnap(raw, lines, PEAK_SNAP_METERS) else { return }
        guard index < workspace.waypoints.count else { return }
        let current = workspace.waypoints[index]
        guard current.lon == raw.lon && current.lat == raw.lat else { return }
        if let peak = peaks.peaks.first(where: { $0.center.lon == match.point.lon && $0.center.lat == match.point.lat }) {
            workspace.waypoints[index].lon = match.point.lon
            workspace.waypoints[index].lat = match.point.lat
            if let name = peak.name { workspace.waypoints[index].name = name }
            workspace.waypoints[index].elevation = peak.elevation
            workspace.save()
        }
    }
}
