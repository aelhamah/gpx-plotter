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
        .background(.bar)
    }

    private var subtitle: String {
        switch packs.state {
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
            Button("Clear") { packs.removeCurrentPack() }
                .buttonStyle(.bordered)
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
    /// When supplied, the figures come from the resampled profile the chart
    /// draws, so the bar and the profile always agree.
    var analysis: RouteAnalysis?

    var body: some View {
        let summary = RouteSummary(route: route, system: workspace.unitSystem, analysis: analysis)
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
    @EnvironmentObject private var services: AppServices

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
                    LabeledContent("Offline tiles") {
                        Text("\(packs.cachedTileCount) · \(packs.cachedSizeDescription)")
                            .foregroundStyle(.secondary)
                    }
                    Button("Clear All Routes", role: .destructive) {
                        workspace.clearAll()
                    }
                    if packs.cachedTileCount > 0 {
                        Button("Clear Offline Maps", role: .destructive) {
                            packs.removeCurrentPack()
                        }
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Tiles are cached as you look at the map, and a corridor download fetches the rest for a route. The cache grows until it is cleared here.")
                }
            }
            .navigationTitle("Settings")
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

    /// - Parameter analysis: the resampled profile to read from. Pass it on the
    ///   viewer screen so these numbers come from the same samples the profile
    ///   chart draws. Left nil (the Maps list) it resamples the route itself,
    ///   which is cheap and needs no network.
    @MainActor
    init?(route: Route, system: UnitSystem, analysis: RouteAnalysis? = nil) {
        guard route.points.count >= 2 else { return nil }
        let profile = analysis?.profile ?? RouteProfile.make(from: route.points)
        distance = Units.formatDistance(profile.totalDistance, system: system)
        let elevation = analysis?.elevation ?? Slope.stats(for: profile.points)
        gain = Units.formatElevation(elevation.gain, system: system)
        loss = Units.formatElevation(elevation.loss, system: system)
        high = Units.formatElevation(elevation.max, system: system)
    }

    var subtitle: String {
        [distance, "↑ \(gain)", "↓ \(loss)"].joined(separator: "  ")
    }
}
