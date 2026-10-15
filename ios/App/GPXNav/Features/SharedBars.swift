import SwiftUI
import RouteKit



/// Offline corridor download, per the plan: route + 1 km buffer, z12–z14.
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
        .frame(height: PanelMetrics.offlineRowHeight)
    }

    private var subtitle: String {
        switch effectiveState {
        case .complete:
            var text = "Ready for airplane mode"
            if packs.skippedTileCount > 0 {
                // Honest about the holes: the map fills them in from the network
                // when there is one, which there is not in airplane mode.
                text += " · \(packs.skippedTileCount) tile\(packs.skippedTileCount == 1 ? "" : "s") unavailable"
            }
            return text
        case .failed(let message):
            return message
        default:
            if let limitation = AppConfig.offlineLimitation {
                return limitation
            }
            let tiles = packs.estimatedTileCount
            guard tiles > 0 else { return packs.pendingEstimateNote }
            return "\(tiles) tiles · about \(packs.estimatedSizeDescription)"
        }
    }

    private var iconName: String {
        switch effectiveState {
        case .complete: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .downloading: return "arrow.down.circle"
        default: return "icloud.and.arrow.down"
        }
    }

    /// This route's pack record, from the manifest rather than the session.
    private var packRecord: OfflinePack? { packs.pack(for: route) }

    /// The bar's view of state, which is the session's state unless the manifest
    /// knows better.
    private var effectiveState: OfflinePackManager.PackState {
        if case .none = packs.state, packs.pack(for: route) != nil { return .complete }
        return packs.state
    }

    private var tint: Color {
        switch effectiveState {
        case .complete: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }

    @ViewBuilder
    private var action: some View {
        switch effectiveState {
        case .complete:
            // Per route, which is what this row is about. It used to wipe the
            // whole cache — including corridors downloaded for other routes —
            // because nothing recorded which tiles belonged to which one.
            // Only offered when there is a record to delete against. Reaching
            // `.complete` always implies one -- a download writes the record as
            // it completes -- so the nil case is not a state to design for, and a
            // button that deletes the wrong tiles is worse than no button.
            if let packRecord {
                Button("Clear") { packs.deletePack(packRecord, route: route) }
                    .buttonStyle(.bordered)
            }
        case .none, .failed:
            Button("Download") {
                packs.download(for: route)
            }
            .buttonStyle(.borderedProminent)
            .disabled(packs.estimatedTileCount == 0 || !AppConfig.canDownloadOffline)
            .help("Fetches every tile this route's corridor covers, for every source the basemap needs")
        case .preparing, .downloading:
            ProgressView()
        }
    }
}

struct RouteStatsBar: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let route: Route
    /// The figures come from the resampled profile the chart draws, so the bar
    /// and the profile always agree.
    ///
    /// Observed, not just held: as a plain property the bar would keep showing
    /// the figures from before the terrain fill published a new profile, which
    /// is how the bar once reported 1,493 ft of ascent next to a chart whose
    /// axis was 3,600 m.
    @ObservedObject var analysis: RouteAnalysis

    var body: some View {
        let summary = RouteSummary(route: route, system: workspace.unitSystem, analysis: analysis)
        VStack(spacing: 0) {
            // Both rows in every detent. They used to be one row when collapsed,
            // which left the short sheet as four figures above a band of empty
            // material — and the three extra figures are the ones a hiker wants
            // most (how low, how steep, how many points) and could not see without
            // expanding to get at a chart they had not asked for.
            row(summary?.primary ?? [])
            if let secondary = summary?.secondary, !secondary.isEmpty {
                row(secondary).padding(.top, 8)
            }
        }
        .padding(.vertical, 10)
        .frame(height: PanelMetrics.statsBlockHeight)
    }

    private func row(_ stats: [(label: String, value: String)]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                statCell(stat.label, stat.value)
            }
        }
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var services: AppServices
    /// `-openStorage` goes straight to the storage screen.
    ///
    /// The capture script has no way to tap, and a screen nothing can photograph
    /// is a screen nobody looks at — which is how the storage screen would have
    /// shipped without anyone seeing it.
    @State private var isShowingStorage = ProcessInfo.processInfo.arguments.contains("-openStorage")

    private var packs: OfflinePackManager { services.offline }

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

                Section {
                    NavigationLink {
                        OfflineStorageScreen(packs: packs)
                    } label: {
                        LabeledContent("Offline maps") {
                            Text("\(packs.packs.count) · \(packs.cachedSizeDescription)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        isShowingStorage = true
                    })
                } header: {
                    Text("Data")
                } footer: {
                    Text("Tiles are cached as you look at the map, and a corridor download fetches the rest for a route. The cache grows until it is cleared from here.")
                }

                Section {
                    Button("Delete All Routes", role: .destructive) {
                        workspace.clearAll()
                    }
                } header: {
                    Text("Library")
                } footer: {
                    // This one used to sit under "Offline tiles" as
                    // "Clear All Routes", which read as though it cleared the
                    // cache and did the opposite: it deletes every route and the
                    // imported file, and leaves every tile on disk.
                    Text("Removes every route from the library and deletes the imported file. Cached map tiles are kept.")
                }
            }
            .navigationTitle("Settings")
            // Pushed rather than presented, so the back-swipe still works and the
            // capture shows a normal push rather than a modal.
            .navigationDestination(isPresented: $isShowingStorage) {
                OfflineStorageScreen(packs: packs)
            }
            .task { await packs.refreshCacheFigures() }
        }
    }
}

/// Route figures, formatted through RouteKit so units stay consistent.
struct RouteSummary {
    let distance: String
    let gain: String
    let loss: String
    let high: String
    let low: String
    let maxSlope: String
    let pointCount: String

    /// - Parameter analysis: the resampled profile to read from. Pass it on the
    ///   viewer screen so these numbers come from the same samples the profile
    ///   chart draws. Left nil (the Maps list) it resamples the route itself,
    ///   which is cheap and needs no network.
    @MainActor
    init?(route: Route, system: UnitSystem, analysis: RouteAnalysis? = nil) {
        guard route.points.count >= 2 else { return nil }
        let profile = analysis?.profile ?? RouteProfile.make(from: route.points)
        distance = Units.formatDistance(profile.totalDistance, system: system)
        // One pass for every elevation figure: `summary` carries gain, loss, the
        // extremes and the steepest segment, and it reads the terrain between
        // vertices rather than only the track's own ones.
        let elevation = Slope.summary(for: profile.points)
        gain = Units.formatElevation(elevation.gain, system: system)
        loss = Units.formatElevation(elevation.loss, system: system)
        high = Units.formatElevation(elevation.max, system: system)
        low = Units.formatElevation(elevation.min, system: system)
        maxSlope = Units.formatSlope(elevation.maxSlope)
        pointCount = Units.grouped(route.points.count)
    }

    /// The figures that fit on one row, in the order the web app shows them.
    var primary: [(label: String, value: String)] {
        [("Distance", distance), ("Ascent", gain), ("Descent", loss), ("High", high)]
    }

    /// The rest, shown only when the panel is expanded.
    var secondary: [(label: String, value: String)] {
        [("Low", low), ("Max slope", maxSlope), ("Points", pointCount)]
    }

    var subtitle: String {
        [distance, "↑ \(gain)", "↓ \(loss)"].joined(separator: "  ")
    }
}
