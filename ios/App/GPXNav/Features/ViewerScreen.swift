import SwiftUI
import RouteKit

/// Full-screen map with the route's figures in a sheet underneath.
///
/// The map fills the display and the figures are an overlay, rather than
/// siblings in a `VStack` — otherwise the map only ever gets half the screen
/// and panning fights the layout. The sheet has two detents: collapsed to the
/// stats bar, and expanded to the stats, the profile, and the offline row. See
/// docs/ios-plan.md §7.
struct ViewerScreen: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var location: LocationController
    @EnvironmentObject private var services: AppServices
    @StateObject private var analysis: RouteAnalysis
    @State private var isPanelPresented = true
    @State private var isSearching = false
    @State private var scrubbedDistance: Double?
    /// Why the basemap is not showing, or nil when it loaded.
    @State private var mapError: String?
    /// Raised by the fit button; `MapView` watches it to frame the route.
    @State private var fitToken = 0
    /// Waypoint names projected into map coordinates, redrawn as the camera moves.
    @State private var waypointLabels: [ProjectedWaypoint] = []
    /// Bumped each time the map finishes loading a style.
    ///
    /// The corridor estimate can only be worked out once `StyleBuilder` knows
    /// which tile sets the basemap needs, so it is redone on every style load
    /// rather than once on appear — which always beat the style and left the
    /// estimate permanently at zero.
    @State private var styleGeneration = 0
    /// Which detent the sheet is at. Bound rather than fixed so `-expandedPanel`
    /// can open it, and so the panel knows which of its two layouts to show
    /// without measuring its own height: `simctl` cannot drag a sheet, and the
    /// profile chart is only in the expanded one.
    @State private var panelDetent: PresentationDetent = ProcessInfo.processInfo
        .arguments.contains("-expandedPanel")
        ? .height(AppConfig.expandedPanelHeight)
        : .height(AppConfig.statsOnlyPanelHeight)

    let route: Route

    init(route: Route) {
        self.route = route
        _analysis = StateObject(wrappedValue: RouteAnalysis(route: route))
    }

    private var packs: OfflinePackManager { services.offline }

    var body: some View {
        content
    }

    /// Rebuilt with the shared cache the first time the environment provides it.
    @ViewBuilder
    private var content: some View {
        MapView(
            route: route,
            scrubbedDistance: $scrubbedDistance,
            loadError: $mapError,
            onStyleLoaded: { styleGeneration += 1 },
            waypointLabels: $waypointLabels,
            fitToken: $fitToken
        )
            .ignoresSafeArea()
            .overlay {
                WaypointLabelOverlay(labels: waypointLabels)
            }
            .overlay(alignment: .top) {
                if let mapError {
                    Label {
                        Text(mapError).font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.red, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 96)
                    .padding(.horizontal, 12)
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    searchButton
                    waypointCount
                }
                .padding(.leading, 12)
                // Clear the translucent navigation bar, which the map now runs under.
                .padding(.top, 52)
            }
            .overlay(alignment: .topTrailing) {
                MapLayerControls()
                    .padding(.trailing, 12)
                    .padding(.top, 52)
            }
            .overlay(alignment: .bottomTrailing) {
                // Lifted clear of the sheet. The panel owns the bottom of the
                // screen, so a flat 12pt inset put the locate button on top of
                // the stats row — and its hit area swallowed taps meant for the
                // figures underneath.
                VStack(spacing: 10) {
                    FitButton { fitToken += 1 }
                    LocateButton()
                }
                .padding(.trailing, 12)
                .padding(.bottom, panelHeight + 12)
            }
            .sheet(isPresented: $isPanelPresented) {
                panel
                    .presentationDetents(
                        [.height(AppConfig.statsOnlyPanelHeight), .height(AppConfig.expandedPanelHeight)],
                        selection: $panelDetent
                    )
                    .presentationBackgroundInteraction(.enabled)
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(20)
            }
            .navigationTitle(route.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: styleGeneration) {
                Task { await packs.estimate(for: route) }
            }
            .task {
                workspace.selectedRouteId = route.id
                await packs.estimate(for: route)
                await packs.refreshCacheFigures()
                analysis.fillMissingElevations()
                if ProcessInfo.processInfo.arguments.contains("-openSearch") {
                    isSearching = true
                }
                // `-scrub 0.4` seeds the profile scrub at a fraction of the
                // route. `simctl` cannot drag, so this is how the map trace gets
                // checked on the simulator.
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "-scrub"),
                   arguments.count > index + 1,
                   let fraction = Double(arguments[index + 1]) {
                    scrubbedDistance = min(max(fraction, 0), 1) * analysis.totalDistance
                }
                // `simctl launch` cannot tap, so `-downloadOffline` starts the
                // corridor pack straight away.
                if ProcessInfo.processInfo.arguments.contains("-downloadOffline"),
                   AppConfig.canDownloadOffline {
                    packs.download(for: route)
                }
            }
            .sheet(isPresented: $isSearching) {
                SearchView(proximity: route.points.first?.coordinate)
            }
    }

    /// The sheet's contents, which change with the detent.
    ///
    /// Collapsed it is just the stats row. Which one is showing is read from the
    /// detent selection rather than measured from this view's own height: a
    /// sheet's content does not otherwise know which detent it is in, and
    /// letting a fixed-height profile sit in the short detent is what clipped
    /// the stats row before.
    private var panel: some View {
        VStack(spacing: 0) {
            RouteStatsBar(route: route, analysis: analysis, isExpanded: !isPanelCompact)

            if !isPanelCompact {
                if let problem = AppConfig.keyProblemDescription {
                    // One line, truncated, with the full explanation in Settings'
                    // Status section and the tooltip. Spelled out here it ran to
                    // three lines and pushed the profile's own bottom edge off the
                    // sheet, which is a bad trade for a message about a
                    // misconfiguration the developer has to fix anyway.
                    Label {
                        Text(problem).font(.caption).lineLimit(1)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                    .help(problem)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                }

                RouteProfileChart(
                    analysis: analysis,
                    route: route,
                    system: workspace.unitSystem,
                    scrubbedDistance: $scrubbedDistance
                )
                .padding(.horizontal)
                .padding(.bottom, 6)

                // The chart is coloured by these bands, so it is explained whether
                // or not the on-map slope overlay happens to be switched on.
                SlopeLegend()

                OfflinePackBar(route: route, packs: packs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The sheet runs to the bottom of the display, so without this the last
        // row — the offline download button — sits under the home indicator and
        // the indicator's tap target swallows presses aimed at it. Padding goes
        // *inside* the background so the material still fills to the screen edge
        // and the bar does not end in a visible seam above the home bar.
        .padding(.bottom, Screen.safeAreaBottom)
        .background(.bar)
    }

    /// Whether the sheet is at its short detent.
    private var isPanelCompact: Bool {
        panelDetent == .height(AppConfig.statsOnlyPanelHeight)
    }

    /// How much of the bottom the sheet currently covers, so the map controls can
    /// sit above it rather than under it.
    private var panelHeight: CGFloat {
        isPanelCompact ? AppConfig.statsOnlyPanelHeight : AppConfig.expandedPanelHeight
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
