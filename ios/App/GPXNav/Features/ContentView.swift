import SwiftUI
import UniformTypeIdentifiers
import RouteKit

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "map") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var path: [Route] = []
    @State private var isImporting = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if workspace.routes.isEmpty {
                    ContentUnavailableView(
                        "No routes yet",
                        systemImage: "square.and.arrow.down",
                        description: Text("Import a GPX file to see it on the map.")
                    )
                }
                ForEach(workspace.routes) { route in
                    Button {
                        path.append(route)
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: route.color))
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(route.name)
                                    .foregroundStyle(.primary)
                                if let summary = RouteSummary(route: route, system: workspace.unitSystem) {
                                    Text(summary.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete { offsets in
                    workspace.routes.remove(atOffsets: offsets)
                    workspace.save()
                }

                if let error = workspace.importError {
                    Section {
                        Label {
                            Text(error)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                        .font(.caption)
                    }
                }
            }
            .navigationTitle(workspace.documentName ?? "Routes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Import", systemImage: "square.and.arrow.down") {
                        isImporting = true
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .navigationDestination(for: Route.self) { route in
                RouteDetailView(route: route)
            }
        }
        .onAppear {
            // `-openFirstRoute` opens the map straight away, so the M0 spike
            // (style + route + overlays) can be driven from `simctl launch`. It
            // prefers the last-opened route, which import and navigation set.
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("-openFirstRoute"), path.isEmpty else { return }
            let selected = workspace.routes.first { $0.id == workspace.selectedRouteId }
            if let route = selected ?? workspace.routes.first {
                path.append(route)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .failure(let error):
            workspace.importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // The picker hands back a security-scoped URL; without this the
            // read fails with a permissions error.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                if workspace.importGPX(text, fileName: url.lastPathComponent) {
                    path.append(workspace.routes[workspace.routes.count - 1])
                }
            } catch {
                workspace.importError = error.localizedDescription
            }
        }
    }
}

struct RouteDetailView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var location: LocationController
    @StateObject private var packs = OfflinePackManager()
    @State private var isSearching = false
    let route: Route

    var body: some View {
        VStack(spacing: 0) {
            MapView(route: route)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottomTrailing) {
                    LocateButton()
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 8) {
                        searchButton
                        waypointCount
                    }
                    .padding(.leading, 12)
                    .padding(.top, 8)
                }

            if let problem = AppConfig.keyProblemDescription {
                Label {
                    Text(problem)
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }

            RouteStatsBar(route: route)
            RouteProfileChart(route: route, system: workspace.unitSystem)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.bar)
            OfflinePackBar(route: route, packs: packs)
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Navigate", systemImage: "location.fill") {}
                    .disabled(true)
            }
        }
        .task {
            workspace.selectedRouteId = route.id
            packs.estimate(for: route)
            // `simctl launch` cannot tap, so these open things directly.
            if ProcessInfo.processInfo.arguments.contains("-openSearch") {
                isSearching = true
            }
            // `-downloadOffline` starts the corridor pack straight away for the
            // M0 offline check.
            if ProcessInfo.processInfo.arguments.contains("-downloadOffline"),
               AppConfig.canDownloadOffline {
                packs.download(route: route, styleURL: AppConfig.styleURL(for: workspace.mapStyle))
            }
        }
        .sheet(isPresented: $isSearching) {
            // The map centre biases results, the way the web app sends its
            // `proximity` parameter.
            SearchView(proximity: route.points.first?.coordinate)
        }
    }

    @ViewBuilder
    private var searchButton: some View {
        if let limitation = AppConfig.searchLimitation {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
                .accessibilityLabel("Search unavailable")
                .help(limitation)
        } else {
            Button {
                isSearching = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Search for a place")
        }
    }

    @ViewBuilder
    private var waypointCount: some View {
        if !workspace.waypoints.isEmpty {
            Text("\(workspace.waypoints.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
                .accessibilityLabel("\(workspace.waypoints.count) waypoints")
        }
    }
}

/// Offline corridor download, per the plan: route + 1 km buffer, z12–z16.
struct OfflinePackBar: View {
    let route: Route
    @ObservedObject var packs: OfflinePackManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(packs.state.label)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            action
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var subtitle: String {
        switch packs.state {
        case .complete:
            return "Ready for airplane mode"
        case .failed(let message):
            return message
        default:
            if let limitation = AppConfig.offlineLimitation {
                return limitation
            }
            let tiles = packs.estimatedTileCount
            guard tiles > 0 else { return "No offline estimate yet" }
            return "\(tiles) tiles · about \(packs.estimatedSizeDescription)"
        }
    }

    private var iconName: String {
        switch packs.state {
        case .complete: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .downloading: return "arrow.down.circle"
        default: return "icloud.and.arrow.down"
        }
    }

    private var tint: Color {
        switch packs.state {
        case .complete: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }

    @ViewBuilder
    private var action: some View {
        switch packs.state {
        case .complete:
            Button("Remove") { packs.removeCurrentPack() }
                .buttonStyle(.bordered)
        case .none, .failed:
            Button("Download") {
                packs.download(route: route, styleURL: AppConfig.styleURL(for: .outdoor))
            }
            .buttonStyle(.borderedProminent)
            .disabled(packs.estimatedTileCount == 0 || !AppConfig.canDownloadOffline)
        case .preparing, .downloading:
            ProgressView()
        }
    }
}

struct RouteStatsBar: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let route: Route

    var body: some View {
        let summary = RouteSummary(route: route, system: workspace.unitSystem)
        HStack(spacing: 0) {
            stat("Distance", summary?.distance ?? "—")
            stat("Ascent", summary?.gain ?? "—")
            stat("Descent", summary?.loss ?? "—")
            stat("High", summary?.high ?? "—")
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Map", selection: $workspace.mapStyle) {
                        ForEach(MapStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!AppConfig.canSwitchBaseLayer)
                } header: {
                    Text("Base Layer")
                } footer: {
                    if let limitation = AppConfig.baseLayerLimitation {
                        Text(limitation)
                    }
                }

                Section {
                    Toggle("Relief (hillshade)", isOn: $workspace.showHillshade)
                        .disabled(!AppConfig.canShowTerrainOverlays)
                    Toggle("Slope shading", isOn: $workspace.showSlope)
                        .disabled(!AppConfig.canShowTerrainOverlays)
                } header: {
                    Text("Terrain")
                } footer: {
                    if let limitation = AppConfig.terrainLimitation {
                        Text(limitation)
                    } else {
                        Text("Relief reads MapTiler Terrain-RGB. Slope shading is generated on device and served to the map over loopback.")
                    }
                }

                Section("Units") {
                    Picker("System", selection: $workspace.unitSystem) {
                        ForEach(UnitSystem.allCases) { system in
                            Text(system == .metric ? "Metric" : "Imperial").tag(system)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Status") {
                    LabeledContent("Basemap", value: AppConfig.basemapStatus)
                }

                Section("Data") {
                    Button("Clear All Routes", role: .destructive) {
                        workspace.clearAll()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// Route figures, formatted through RouteKit so units stay consistent.
struct RouteSummary {
    let distance: String
    let gain: String
    let loss: String
    let high: String

    init?(route: Route, system: UnitSystem) {
        guard route.points.count >= 2 else { return nil }
        distance = Units.formatDistance(Haversine.routeLength(route.points), system: system)
        let elevation = Slope.stats(for: route.points)
        gain = Units.formatElevation(elevation.gain, system: system)
        loss = Units.formatElevation(elevation.loss, system: system)
        high = Units.formatElevation(elevation.max, system: system)
    }

    var subtitle: String {
        [distance, "↑ \(gain)", "↓ \(loss)"].joined(separator: "  ")
    }
}
