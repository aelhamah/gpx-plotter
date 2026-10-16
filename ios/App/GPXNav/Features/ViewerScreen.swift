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
    /// Whether live guidance is presented over the viewer.
    @State private var isNavigating = false
    /// Bumped each time the map finishes loading a style.
    ///
    /// The corridor estimate can only be worked out once `StyleBuilder` knows
    /// which tile sets the basemap needs, so it is redone on every style load
    /// rather than once on appear — which always beat the style and left the
    /// estimate permanently at zero.
    @State private var styleGeneration = 0
    /// Whether the sheet is showing its tall layout.
    ///
    /// A flag rather than a `PresentationDetent`, because the heights are now
    /// computed from `PanelMetrics` and the display's safe-area inset — neither of
    /// which is known until the view is on screen. Storing a detent in `@State`
    /// means freezing a height decided before the device was, which is how the
    /// figures ended up half-hidden behind the rounded corner on a device that
    /// did not match the one the height was measured on.
    @State private var isPanelExpanded: Bool = ProcessInfo.processInfo
        .arguments.contains("-expandedPanel")

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
                        Image(systemName: "key.slash.fill")
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
                    .presentationDetents(panelDetents, selection: panelDetentBinding)
                    .presentationBackgroundInteraction(.enabled)
                    .presentationDragIndicator(.hidden)
                    // No `presentationCornerRadius`. A sheet's own corner radius is
                    // derived from the display's, and there is no public API to read
                    // the display's — `UIListContentConfiguration.cornerRadius` and
                    // friends are content-configuration radii, and iOS 26's
                    // `UICornerRadius.containerConcentric` has no SwiftUI equivalent
                    // for this modifier yet. Setting it to a number therefore
                    // overrides a correct value with a guessed one, which is how the
                    // sheet came out visibly squarer than the phone's own corner.
            }
            .navigationTitle(route.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // `figure.hiking`, not `location.fill`: the locate button
                    // directly below it already used that glyph, and two
                    // identical icons meaning "start navigating" and "centre on
                    // me" is what #67 was about. This one now matches the glyph
                    // the Live Activity uses for a hike in progress.
                    Button("Navigate", systemImage: "figure.hiking") {
                        beginNavigation()
                    }
                    // A route with fewer than two points has no line to follow, so
                    // there is nothing to navigate. Greyed with the reason in the
                    // tooltip rather than hidden, so the feature is discoverable.
                    .disabled(route.points.count < 2)
                    .help(route.points.count < 2 ? "This route has no line to follow." : "Start live guidance")
                }
            }
            .fullScreenCover(isPresented: $isNavigating) {
                NavigationScreen(
                    route: route,
                    waypoints: workspace.waypoints,
                    // The viewer's own terrain-filled profile, so the nav readout
                    // and the chart above it cannot disagree about the climb.
                    profile: analysis.profile
                )
                .environmentObject(workspace)
                .environmentObject(location)
            }
            .onChange(of: styleGeneration) {
                Task { await packs.estimate(for: route) }
            }
            .task {
                workspace.selectedRouteId = route.id
                // `simctl launch` cannot tap, so `-navigate` opens live guidance
                // straight away. Pair it with `xcrun simctl location <device> set
                // <lat>,<lon>` to walk the route without leaving the desk.
                if ProcessInfo.processInfo.arguments.contains("-navigate") {
                    beginNavigation()
                }
                await packs.estimate(for: route)
                await packs.refreshCacheFigures()
                // Opt-in (#72). The terrain fill used to run on every open, so a
                // route was quietly re-drawn from MapTiler's ground model before
                // anyone had asked for it, and a route recorded with a barometric
                // altimeter was silently second-guessed by a 30 m DEM tile. With
                // the setting off the profile is the file's own elevations and
                // the lines between them, which is what was imported and what a
                // GPX reader is expected to show.
                if workspace.fillsMissingElevation {
                    analysis.fillMissingElevations()
                }
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
            // In place of the system drag indicator, which is replaced so the
            // collapsed sheet says what the drag will do. A grabber alone left the
            // short detent reading as a dead white band: the four figures, then
            // roughly 60 pt of nothing, which looks broken rather than collapsed.
            PanelExpandChevron(isExpanded: !isPanelCompact)

            RouteStatsBar(route: route, analysis: analysis)

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
                        Image(systemName: "key.slash.fill")
                    }
                    .foregroundStyle(.orange)
                    .help(problem)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .frame(height: PanelMetrics.keyWarningHeight)
                }

                RouteProfileChart(
                    analysis: analysis,
                    route: route,
                    system: workspace.unitSystem,
                    scrubbedDistance: $scrubbedDistance
                )
                .padding(.horizontal)
                .padding(.bottom, PanelMetrics.chartSpacing)
                // Sized rather than left to `.frame(maxHeight: .infinity)`: a
                // sheet's content is proposed its ideal height, not the detent's,
                // so a flexible frame never actually claims the slack and the
                // panel kept ~64pt of empty material under the offline row.
                // Computing it here means the chart takes whatever this layout has
                // left, so a panel with no key warning — or one whose scrub caption
                // has gone after the first drag — shows more profile instead.
                .frame(height: chartRowHeight)

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

    /// The sheet's two heights, derived from `PanelMetrics` and this display's
    /// bottom inset.
    private var panelDetents: Set<PresentationDetent> {
        let safeArea = Screen.safeAreaBottom
        return [
            .height(AppConfig.collapsedPanelHeight(safeAreaBottom: safeArea)),
            .height(AppConfig.expandedPanelHeight(safeAreaBottom: safeArea)),
        ]
    }

    /// Maps the sheet's height back to the flag, so a drag updates the flag and
    /// the panel's own layout follows it.
    private var panelDetentBinding: Binding<PresentationDetent> {
        let collapsed = AppConfig.collapsedPanelHeight(safeAreaBottom: Screen.safeAreaBottom)
        let expanded = AppConfig.expandedPanelHeight(safeAreaBottom: Screen.safeAreaBottom)
        return Binding(
            get: { .height(isPanelExpanded ? expanded : collapsed) },
            // `PresentationDetent.height(_:)` is a static function rather than an
            // enum case, so a detent cannot be pattern-matched to read its value;
            // comparing against the two we offered is both simpler and exact.
            set: { isPanelExpanded = $0 == .height(expanded) }
        )
    }

    /// Open live guidance, taking the figures sheet down first.
    ///
    /// The order matters: both presentations hang off this same view, and SwiftUI
    /// will not present a `fullScreenCover` while a `.sheet` from the same
    /// hierarchy is still up — the flag flips and nothing appears. Dropping the
    /// panel first also means the readout is not competing with the stats for the
    /// screen.
    private func beginNavigation() {
        isPanelPresented = false
        // One runloop later, so the sheet's dismissal has been committed before
        // the cover is asked for. Setting both in the same transaction is what
        // loses one of them.
        Task { @MainActor in
            isNavigating = true
        }
    }

    /// Whether the sheet is at its short detent.
    private var isPanelCompact: Bool { !isPanelExpanded }

    /// Height the profile row takes: whatever the fixed rows do not use.
    ///
    /// The warning is counted only when it is actually on screen, so the chart
    /// grows by exactly the row that disappeared rather than the sheet leaving a
    /// gap of the same size somewhere else.
    private var chartRowHeight: CGFloat {
        let fixed = PanelMetrics.expandChevronHeight
            + PanelMetrics.statsBlockHeight
            + PanelMetrics.chartSpacing
            + PanelMetrics.legendHeight
            + PanelMetrics.offlineRowHeight
            + (AppConfig.keyProblemDescription == nil ? 0 : PanelMetrics.keyWarningHeight)
        let available = panelHeight - Screen.safeAreaBottom - fixed
        return max(PanelMetrics.chartMinimumHeight, available)
    }

    /// How much of the bottom the sheet currently covers, so the map controls can
    /// sit above it rather than under it.
    private var panelHeight: CGFloat {
        isPanelExpanded
            ? AppConfig.expandedPanelHeight(safeAreaBottom: Screen.safeAreaBottom)
            : AppConfig.collapsedPanelHeight(safeAreaBottom: Screen.safeAreaBottom)
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
