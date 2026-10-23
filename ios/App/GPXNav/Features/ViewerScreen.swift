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
    /// Base layer and overlay choice, behind the globe in the control pill.
    @State private var isShowingMapModes = false
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
    /// The highest zoom the loaded basemap actually serves, read back from the
    /// style once `StyleBuilder` has built it.
    ///
    /// The map needs this to keep the camera inside the tile ceiling — see
    /// `StyleBuilder.maxZoom(for:)`, which is the long version of why an
    /// uncapped fit turned the basemap into a blank canvas.
    @State private var maxBasemapZoom: Double?
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
    /// Frames of the chrome drawn over the map, reported by the chrome itself
    /// through `ChromeFramesPreference`; read by `mapInsets`.
    @State private var chromeFrames: [String: CGRect] = [:]

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
    ///
    /// The gate lives in `baseMap` rather than here: an `if` inside this
    /// modifier chain stalls the type checker ("unable to type-check this
    /// expression in reasonable time"), and splitting it costs nothing.
    @ViewBuilder
    private var baseMap: some View {
        // The map itself waits for the loopback to bind. MapLibre asks for
        // `style.json` the moment the view exists, treats a refused ask as
        // final, and a style this process never sees leaves every tile a 404
        // it will not retry — the flat-grey basemap. The placeholder is the
        // system background, which is also what the map paints before its
        // first tile, so the swap is invisible in practice.
        if services.serverReady {
            MapView(
                route: route,
                scrubbedDistance: $scrubbedDistance,
                loadError: $mapError,
                onStyleLoaded: { styleGeneration += 1 },
                waypointLabels: $waypointLabels,
                fitToken: $fitToken,
                maxBasemapZoom: maxBasemapZoom,
                mapInsets: mapInsets
            )
        } else {
            Color(.systemBackground)
        }
    }

    private var content: some View {
        baseMap
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
                    // The banner is an obstacle while it is up, and its frame
                    // has to be the red pill's — measured, so a label cannot
                    // hide behind it, and gone the moment the error clears.
                    .chromeFrame("errorBanner")
                    .padding(.top, 96)
                    .padding(.horizontal, 12)
                }
            }
            .overlay(alignment: .topLeading) {
                waypointCount
                    .padding(.leading, 12)
                    // Sits just under the navigation bar rather than 52pt below
                    // it. The bar is 113pt on a notched device and the rails are
                    // bottom-anchored, so every point this sits lower is a point
                    // taken out of the space the rails need at the expanded
                    // detent. See `MapChrome.railHeight`.
                    .padding(.top, 12)
                    // Its frame is the top edge the labels must clear — the
                    // padded frame starts exactly at the content region's top,
                    // which is where the navigation bar ends. The search button
                    // that used to sit here is gone (it never worked while the
                    // figures sheet is up — see docs/dev.md); the waypoint chip,
                    // when there is one, still has to be avoided.
                    .chromeFrame("topLeading")
            }
            // The slope legend, on the map at the web app's own corner: it
            // explains the map's slope shading, so it belongs with the shading
            // rather than under the profile chart, which is where it used to
            // sit. Gated with the panel: it is sheet-anchored, and a legend
            // standing over a dismissed sheet is the same orphanage as the rails.
            .overlay(alignment: .bottomTrailing) {
                if isPanelPresented, workspace.showSlope {
                    SlopeLegend()
                        .padding(.trailing, 12)
                        .padding(.bottom, MapChrome.bottomInset(panelHeight: panelHeight)
                            + MapChrome.pillHeight + MapChrome.railInset)
                        .chromeFrame("slopeLegend")
                }
            }
            // Both rails, anchored to the sheet rather than to opposite ends of
            // the screen. They move with the sheet and share one band of known
            // height, so they cannot converge — see `MapChrome` for the geometry
            // that used to let them. And they stand only while the sheet does:
            // `bottomInset(panelHeight:)` measures the *detent*, not the live
            // sheet, so with the panel down the rails would sit at their old
            // height over bare map — the floating icons. The panel is only ever
            // down while navigation's cover is coming up or going away, so this
            // is the gap between those, not a state anyone can park in.
            .overlay(alignment: .bottom) {
                if isPanelPresented {
                    HStack(alignment: .bottom) {
                        MapControlRail { fitToken += 1 }
                        Spacer(minLength: 0)
                        MapControlPill { isShowingMapModes = true }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, MapChrome.bottomInset(panelHeight: panelHeight))
                }
            }
            .sheet(isPresented: $isShowingMapModes) {
                MapModesSheet()
                    .environmentObject(workspace)
            }
            .sheet(isPresented: $isPanelPresented) {
                panel
                    // The sheet's own top edge, measured: label layout needs it
                    // and no amount of detent arithmetic stayed honest with it.
                    .chromeFrame("panel")
                    .presentationDetents(panelDetents, selection: panelDetentBinding)
                    .presentationBackgroundInteraction(.enabled)
                    .presentationDragIndicator(.hidden)
                    // Not dismissible by swipe. A swiped-away panel left the
                    // rails and the legend standing where the sheet had been —
                    // floating over the map with no figures and nothing to put
                    // them back — and taking it down is something only this app
                    // should do (navigation, below, which brings it back on the
                    // way out). Collapsing to the short detent is still what the
                    // drag is for, so the map can be got out of the way.
                    .interactiveDismissDisabled(true)
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
                .environmentObject(services)
            }
            .onChange(of: isNavigating) {
                // Live guidance is the one thing that takes the figures sheet
                // down (a cover will not present over a sheet from the same
                // hierarchy — see `beginNavigation`), and nothing used to bring
                // it back: the viewer returned with its rails floating over a
                // bare map and no way to summon the figures again. The sheet
                // comes back with the screen it left.
                if !isNavigating {
                    isPanelPresented = true
                }
            }
            .onChange(of: styleGeneration) {
                Task { await packs.estimate(for: route) }
                // Re-read on every style load, not once on appear: the ceiling is
                // a property of the style that just loaded, so it changes with the
                // base layer, and reading it before the first build would pin the
                // map to the fallback for the whole session.
                let style = workspace.mapStyle
                Task {
                    let ceiling = await services.styleBuilder.maxZoom(for: style)
                    if workspace.mapStyle == style {
                        maxBasemapZoom = ceiling
                    }
                }
            }
            .onChange(of: workspace.mapStyle) {
                // Until the new style reports, hold the ceiling at *its*
                // fallback rather than the previous style's number — a camera
                // carried across the swap is clamped against this in
                // `applyZoomCeiling`, and clamping a satellite camera against
                // outdoor's ceiling (or the reverse) is the wrong figure either
                // way for as long as the fetch takes.
                maxBasemapZoom = nil
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
            // The chrome reports where it drew itself; `mapInsets` turns those
            // frames into the region the waypoint labels may use. Guarded on
            // equality because preferences can re-fire with the same value, and
            // every firing would otherwise re-run the label layout.
            .onPreferenceChange(ChromeFramesPreference.self) { frames in
                if frames != chromeFrames {
                    chromeFrames = frames
                }
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
            + PanelMetrics.offlineRowHeight
            + (AppConfig.keyProblemDescription == nil ? 0 : PanelMetrics.keyWarningHeight)
        // No `legendHeight`: the slope legend moved to the map (see its overlay
        // above), so the chart absorbs the row it used to sit in, exactly as it
        // absorbs the key warning when there is none. The detent itself is
        // unchanged — `AppConfig.expandedPanelHeight` still counts the row, and
        // the chart is what takes up the slack.
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

    /// What the map has to keep clear of, in its own coordinates.
    ///
    /// Every edge and obstacle comes from a frame the chrome measured about
    /// itself (`ChromeFramesPreference`), in screen coordinates — the same
    /// space the map's projection and the label overlay use. Deriving these
    /// from detents, paddings and safe-area constants meant every layer of the
    /// stack had to agree about them; when the rails' derived band came out
    /// 49pt below where the buttons actually sat, nothing in the app could
    /// tell — the labels just went under the buttons.
    ///
    /// The rails, the waypoint chip's band and the slope legend are obstacles
    /// rather than edge insets because they are columns, not borders: an inset
    /// along an edge would cost every label near it, where an obstacle costs
    /// only the ones that would have landed under a button.
    private var mapInsets: MapInsets {
        let screen = UIScreen.main.bounds
        // A little slack, so a label beside a button does not look glued to it
        // rather than merely clear of it.
        let slack: CGFloat = 4

        let topLeading = chromeFrames["topLeading"]
        let rail = chromeFrames["rail"]
        let pill = chromeFrames["pill"]
        let legend = chromeFrames["slopeLegend"]
        // The sheet runs to the screen's edge and its detent is measured above
        // the home indicator, so the sheet is `safeAreaBottom` taller than
        // `panelHeight`. Used only until the sheet has reported its own frame.
        let panelTop = chromeFrames["panel"]?.minY
            ?? (screen.height - panelHeight - Screen.safeAreaBottom)

        var obstacles: [CGRect] = []
        for frame in [topLeading, rail, pill, legend] {
            if let frame {
                obstacles.append(frame.insetBy(dx: -slack, dy: -slack))
            }
        }
        if let errorBanner = chromeFrames["errorBanner"] {
            obstacles.append(errorBanner.insetBy(dx: -slack, dy: -slack))
        }

        return MapInsets(
            // Below the navigation bar: the top-leading row's top edge is
            // exactly where the content region starts.
            top: topLeading?.minY ?? Screen.topChrome,
            // Up to the sheet's top edge — the rails sit inside that band and
            // are avoided as obstacles rather than by lifting this further.
            bottom: screen.height - panelTop,
            obstacles: obstacles
        )
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
