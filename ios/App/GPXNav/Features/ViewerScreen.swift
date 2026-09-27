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
    @StateObject private var packs: OfflinePackManager
    @StateObject private var analysis: RouteAnalysis
    @State private var isPanelPresented = true
    @State private var isSearching = false
    @State private var scrubbedDistance: Double?

    let route: Route

    init(route: Route) {
        self.route = route
        _packs = StateObject(wrappedValue: OfflinePackManager())
        _analysis = StateObject(wrappedValue: RouteAnalysis(route: route))
    }

    var body: some View {
        MapView(route: route, scrubbedDistance: $scrubbedDistance)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    searchButton
                    waypointCount
                }
                .padding(.leading, 12)
                // Clear the translucent navigation bar, which the map now runs under.
                .padding(.top, 52)
            }
            .overlay(alignment: .bottomTrailing) {
                LocateButton()
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
            }
            .sheet(isPresented: $isPanelPresented) {
                panel
                    .presentationDetents([.height(AppConfig.statsOnlyPanelHeight), .large])
                    .presentationBackgroundInteraction(.enabled)
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(20)
            }
            .navigationTitle(route.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                workspace.selectedRouteId = route.id
                packs.estimate(for: route)
                analysis.fillMissingElevations()
                if ProcessInfo.processInfo.arguments.contains("-openSearch") {
                    isSearching = true
                }
                // `simctl launch` cannot tap, so `-downloadOffline` starts the
                // corridor pack straight away.
                if ProcessInfo.processInfo.arguments.contains("-downloadOffline"),
                   AppConfig.canDownloadOffline {
                    packs.download(route: route, styleURL: AppConfig.styleURL(for: workspace.mapStyle))
                }
            }
            .sheet(isPresented: $isSearching) {
                SearchView(proximity: route.points.first?.coordinate)
            }
    }

    /// The sheet's contents, which change with the detent.
    ///
    /// Collapsed it is just the stats row — the "just the stats" state. The
    /// height is read rather than assumed, because a sheet's content does not
    /// otherwise know which detent it is in, and letting a fixed-height profile
    /// sit in the short detent is what clipped the stats before.
    private var panel: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.height < AppConfig.expandedPanelThreshold
            VStack(spacing: 0) {
                RouteStatsBar(route: route, analysis: analysis)

                if !isCompact {
                    if let problem = AppConfig.keyProblemDescription {
                        Label {
                            Text(problem).font(.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
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

                    OfflinePackBar(route: route, packs: packs)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .background(.bar)
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
