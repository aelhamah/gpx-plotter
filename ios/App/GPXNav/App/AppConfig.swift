import Foundation
import RouteKit
import UIKit

/// App-wide configuration. The MapTiler key is injected at build time from
/// `Secrets.xcconfig` (gitignored) and read back from `Info.plist`, so it never
/// has to be committed.
enum AppConfig {
    /// Which basemap to load.
    enum StyleSource: Equatable {
        /// MapTiler `outdoor-v2` / `satellite-v4` (needs a key allowed for native).
        case mapTiler
        /// MapLibre's public demo tiles — no key, no account.
        case mapLibreDemo
    }

    /// Where `SlopeServer` listens, and the template the map style points at.
    /// Native has no `addProtocol` equivalent, so slope rasters are served
    /// over loopback HTTP (see docs/ios-plan.md §6).
    static let slopePort: UInt16 = 8080
    static var slopeTileURLTemplate: String {
        "http://127.0.0.1:\(slopePort)/slope/{z}/{x}/{y}.png"
    }

    /// Padding left around a route when the camera fits to it, so the polyline
    /// is not flush against the screen edge or hidden under the stats bar.
    static let fitEdgePadding = UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40)

    /// Whether the keyless basemap was asked for on the command line.
    static var isDemoRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-demoTiles")
    }

    static var styleSource: StyleSource {
        // `-demoTiles` forces the keyless basemap, which is how the MapLibre half
        // of the M0 spike gets verified without spending MapTiler quota.
        if isDemoRequested {
            return .mapLibreDemo
        }
        return hasTileProxy ? .mapTiler : .mapLibreDemo
    }

    /// True when the demo basemap is only up because the proxy URL never arrived.
    ///
    /// Falling back silently is how a missing configuration once looked exactly
    /// like a working demo run: the map drew, and only the disabled terrain/offline
    /// controls hinted that the MapTiler basemap was unavailable. This flag lets
    /// the UI say so out loud.
    static var isKeyMissingFallback: Bool {
        styleSource == .mapLibreDemo && !isDemoRequested
    }

    static var hasTileProxy: Bool { tileProxyBaseURL != nil }

    /// Config for the DEM tile store. `nil` on the demo basemap, because the
    /// public demo tileset ships no Terrain-RGB endpoint we can authenticate.
    static var terrainConfig: MapTilerConfig? {
        tileProxyBaseURL.map(MapTilerConfig.init(baseURL:))
    }

    /// The same DEM config for the style builder, which runs off the main actor.
    static var terrainTileConfig: MapTilerConfig? { terrainConfig }

    /// The style URL the map should load.
    ///
    /// With a MapTiler key this is the **loopback** style endpoint, because 3D
    /// terrain has to be in the style JSON: MapLibre Native has no `setTerrain`
    /// equivalent, so the `terrain` block is injected server-side. The `terrain`
    /// query is what makes a toggle change the URL, and therefore force MapLibre
    /// to reload the style — there is no other way to add or drop the block.
    static func mapStyleURL(for style: MapStyle, terrain3D: Bool) -> URL {
        guard hasTileProxy else { return demoStyleURL }
        var components = URLComponents(string: "http://127.0.0.1:\(slopePort)/style.json")!
        components.queryItems = [
            URLQueryItem(name: "style", value: style.rawValue),
            URLQueryItem(name: "terrain", value: terrain3D ? "1" : "0"),
        ]
        return components.url!
    }

    static let demoStyleURL = URL(string: "https://demotiles.maplibre.org/style.json")!

    /// The basemap and elevation tiles the style points at, served by the
    /// loopback caching proxy. Every tile request therefore passes through disk,
    /// which is what makes an offline map possible at all.
    ///
    /// The source name and the format extension are both in the path, because
    /// the style's sources are *different* tile sets at the same coordinates
    /// (`outdoor`, `contours`, `maptiler_planet`, and on the satellite basemap a
    /// raster `satellite`), and one shared template would serve the wrong bytes.
    static func cachedTileURLTemplate(forSource source: String, format: TileFormat) -> String {
        loopbackBase + TileCacheKey(source: source, z: 0, x: 0, y: 0, format: format).loopbackTemplate
    }

    static var loopbackBase: String { "http://127.0.0.1:\(slopePort)" }

    /// Style source id for elevation. One name for the style's `raster-dem`
    /// source, the hillshade layer, the slope generator's DEM fetch, and the
    /// cache file prefix, so all four agree on what "the DEM" is.
    static let demSource = "terrain"

    /// Terrain-RGB tiles, through the loopback cache so hillshade and 3D terrain
    /// survive being offline.
    static var demTileURLTemplate: String {
        guard styleSource == .mapTiler else {
            // Terrarium-encoded demo terrain, straight from MapLibre's public
            // tileset. `MLNRasterDEMSource` documents support for the Mapbox
            // Terrain-RGB encoding only, so relief is expected to stay blank
            // here — it exists to exercise the wiring, not to prove the encoding.
            // The demo basemap has no key, and offline is not a goal.
            return "https://demotiles.maplibre.org/terrain-tiles/{z}/{x}/{y}.png"
        }
        return cachedTileURLTemplate(forSource: demSource, format: .webp)
    }

    /// Camera pitch with 3D terrain on, matching the web app's `easeTo`.
    static let terrainPitch: CGFloat = 55

    /// Upper bound on the zoom the navigation follow picks for itself, when it
    /// frames the accuracy halo from a fix that claims to be very good.
    ///
    /// The halo framing is what the locate button uses; navigation allows one
    /// level closer, because a hiker wants to see the trail under their feet
    /// rather than a 60px circle around it.
    static let navigationFollowMaxZoom = 16.0

    /// Height of the sheet's short detent: the expand affordance and the figures.
    ///
    /// Computed from `PanelMetrics` and the display's bottom inset rather than
    /// written down. Hardcoding it is what let the figures end up half-hidden
    /// behind the sheet's rounded corner on a device whose inset differed from the
    /// one the number was measured on.
    @MainActor
    static func collapsedPanelHeight(safeAreaBottom: CGFloat) -> CGFloat {
        PanelMetrics.expandChevronHeight
            + PanelMetrics.statsBlockHeight
            + safeAreaBottom
    }

    /// Height of the sheet's tall detent: the figures, the profile, the slope
    /// legend, and the offline row, and nothing more.
    ///
    /// Sized for the **tallest** layout — every optional row present — because the
    /// profile chart is flexible and absorbs whatever is left over. Under-reporting
    /// here would shrink the chart rather than show more of it, and the rows that
    /// come and go are the warning (no MapTiler key) and the scrub caption (gone
    /// after the first drag).
    ///
    /// `.large` was rejected: it covers almost the whole display, and the map has
    /// to stay visible while the sheet is up, because scrubbing the profile traces
    /// the position on it.
    @MainActor
    static func expandedPanelHeight(safeAreaBottom: CGFloat) -> CGFloat {
        PanelMetrics.expandChevronHeight
            + PanelMetrics.statsBlockHeight
            + PanelMetrics.keyWarningHeight
            + PanelMetrics.chartHeight
            + PanelMetrics.chartSpacing
            + PanelMetrics.legendHeight
            + PanelMetrics.offlineRowHeight
            + safeAreaBottom
    }

    /// Whether 3D terrain can be switched on. Needs the proxy: the demo basemap has
    /// no Terrain-RGB source to point the terrain block at.
    static var canUseTerrain3D: Bool { hasTileProxy }

    static var terrain3DLimitation: String? {
        canUseTerrain3D
            ? nil
            : "3D terrain needs MapTiler's Terrain-RGB tiles. The demo basemap serves Terrarium terrain, which MapLibre's raster-DEM source cannot decode."
    }

    /// - Parameter terrain3D: whether the style should carry a 3D terrain
    ///   block. Callers that only need a style for tile requests can ignore it.
    static func styleURL(for style: MapStyle, terrain3D: Bool = false) -> URL {
        // Debug override: point the app at a local server to inspect the exact
        // request headers iOS sends. Set GPXNAV_STYLE_URL when launching.
        if let override = ProcessInfo.processInfo.environment["GPXNAV_STYLE_URL"],
           let url = URL(string: override) {
            return url
        }
        guard styleSource == .mapTiler else { return demoStyleURL }
        return mapStyleURL(for: style, terrain3D: terrain3D)
    }

    /// Base URL of the tile proxy, or `nil` when it was never configured.
    ///
    /// The MapTiler key is no longer in the app at all — it lives in the proxy's
    /// secrets — so what the app needs is the address of the thing that has it.
    /// An unset value falls back to MapLibre's demo basemap and says so on screen.
    private static var tileProxyBaseURL: String? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "TileProxyBaseURL") as? String,
              !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return base
    }

    /// Shared geocoding client, or `nil` without the proxy.
    ///
    /// Carries the same identity as the map's tile requests, because the proxy
    /// authenticates on an exact `User-Agent` match: a geocoder that identified
    /// differently from the map would be refused, and search would silently
    /// return no results with nothing on screen to say why.
    static let geocodingClient: GeocodingClient? = tileProxyBaseURL.map { base in
        GeocodingClient(
            httpClient: DefaultHTTPClient(userAgent: MapNetworkIdentity.userAgent),
            baseURL: base
        )
    }

    /// Why search is unavailable, or nil when it works.
    static var searchLimitation: String? {
        geocodingClient == nil
            ? "Search needs the tile proxy. The demo basemap has no geocoder."
            : nil
    }

    // MARK: - What actually works right now

    /// Whether the MapTiler basemaps can be selected.
    ///
    /// On the keyless demo basemap there is only one style, so the base-layer
    /// picker would silently do nothing.
    static var canSwitchBaseLayer: Bool { styleSource == .mapTiler }

    /// Whether terrain overlays can be shown.
    ///
    /// Both need an elevation source: relief reads Terrain-RGB directly from
    /// MapTiler, and slope shading reads the DEM that feeds the loopback server.
    /// The public demo tileset serves Terrarium terrain, which
    /// `MLNRasterDEMSource` does not document support for, so relief stays
    /// blank there.
    static var canShowTerrainOverlays: Bool { styleSource == .mapTiler }

    /// One-line explanation for the Settings screen.
    static var basemapStatus: String {
        if isKeyMissingFallback {
            return "Tile proxy missing — demo tiles"
        }
        switch styleSource {
        case .mapTiler:
            return "MapTiler via tile proxy"
        case .mapLibreDemo:
            return "MapLibre demo tiles — tile proxy not configured"
        }
    }

    /// Why the app is on demo tiles despite no `-demoTiles` flag, or nil when
    /// that is not the case.
    static var keyProblemDescription: String? {
        guard isKeyMissingFallback else { return nil }
        return "No tile proxy URL reached the app, so it fell back to the demo basemap. Check TILE_PROXY_BASE_URL in Secrets.xcconfig — it has to be a real entry in GPXNav/Info.plist, because Xcode drops custom INFOPLIST_KEY_* names."
    }

    /// Why the terrain toggles are unavailable, or nil when they work.
    static var terrainLimitation: String? {
        canShowTerrainOverlays
            ? nil
            : "Relief and slope shading need MapTiler's Terrain-RGB tiles, which require a MapTiler key that allows this app. The demo basemap serves Terrarium terrain, which MapLibre's raster-DEM source cannot decode."
    }

    /// Why the base-layer picker is unavailable, or nil when it works.
    static var baseLayerLimitation: String? {
        canSwitchBaseLayer
            ? nil
            : "The demo basemap has no satellite variant. Add a MapTiler key to switch between Outdoor and Satellite."
    }

    // MARK: - Offline

    /// Zoom range downloaded for offline use, per the plan (§9).
    ///
    /// Capped at z14 because that is the highest zoom MapTiler's `outdoor-v2`
    /// style serves; asking for z15–16 would only ever produce empty tiles.
    static let offlineZoomRange = 12...14

    /// The highest zoom to let the camera reach, when `StyleBuilder` has not yet
    /// reported the loaded style's own ceiling.
    ///
    /// A stopgap for the window between "the map is on screen" and "the style
    /// finished building", and a backstop if that build ever fails: MapLibre
    /// clamps gestures against `maximumZoomLevel`, so without this a pinch on a
    /// cold map can outrun the ceiling and leave the user staring at nothing.
    /// Once the real figure arrives `MapView` uses that instead — see
    /// `StyleBuilder.maxZoom(for:)` for why the two basemaps differ so much.
    ///
    /// Biased low deliberately. Refusing a zoom that would have worked costs one
    /// gesture; allowing one that does not costs the user their map.
    static func fallbackMaxZoom(for style: MapStyle) -> Double {
        switch styleSource {
        case .mapTiler:
            // `outdoor-v2`'s vector sources stop at 14; `satellite-v4`'s imagery
            // raster runs to 18.
            style == .satellite ? 18 : 14
        case .mapLibreDemo:
            // MapLibre's public demo tileset is z0–6, which is why the terrain
            // overlays and the offline download are disabled on it.
            6
        }
    }

    /// How much deliberately downloaded map data to keep before the storage screen
    /// offers to free some up.
    ///
    /// A budget rather than a hard cap: nothing is deleted without being asked
    /// for, because a corridor the hiker downloaded last week is not the app's to
    /// throw away on its own judgement. 200 MB is roughly forty demo-length
    /// corridors, or one long trail with several basemap sources.
    static let offlineByteBudget = 200_000_000

    /// Whether a corridor can be downloaded.
    ///
    /// Needs a key: the download is a prefetch through the loopback cache, and
    /// the public demo tileset stops at z6, so a z12–14 corridor has nothing to
    /// fetch.
    static var canDownloadOffline: Bool {
        styleSource == .mapTiler
    }

    /// Why offline download is unavailable, or nil when it works.
    static var offlineLimitation: String? {
        guard canDownloadOffline else {
            return "Offline download needs a basemap that serves z\(offlineZoomRange.lowerBound)–\(offlineZoomRange.upperBound). The demo tileset stops at z6, so there is nothing to download."
        }
        return nil
    }
}

/// Every height in the route screen's bottom sheet, in one place.
///
/// These were hand-added to the detent arithmetic in a comment, and were wrong
/// twice, which is the whole reason this type exists. The failure is silent: a
/// sheet whose content is taller than its detent does not scroll, it **compresses
/// from the top**, so the first row is what vanishes — a chevron once measured
/// 22pt in a layout pass while painting as a 3pt sliver.
///
/// Each row below is applied as an explicit `.frame(height:)` by the view that
/// draws it, so the declared height and the measured height are the same number
/// and cannot drift apart. Measured on the iPhone 17 Pro simulator, which is the
/// worst case for the text-driven rows; larger type or a taller bottom inset will
/// need these revisited, and the arithmetic in `AppConfig` will carry the change
/// to both detents on its own.
enum PanelMetrics {
    /// The expand/collapse affordance replacing the system drag indicator.
    static let expandChevronHeight: CGFloat = 28

    /// Both rows of route figures and the gap between them, padding included.
    static let statsBlockHeight: CGFloat = 89

    /// The key-missing warning. Only present with no MapTiler key.
    static let keyWarningHeight: CGFloat = 24

    /// The six avalanche slope bands.
    static let legendHeight: CGFloat = 47

    /// The offline download row. Tallest when its explanation wraps to two lines.
    static let offlineRowHeight: CGFloat = 71

    /// Padding under the profile chart.
    static let chartSpacing: CGFloat = 6

    /// Floor for the profile chart, so it cannot collapse on a short sheet.
    static let chartMinimumHeight: CGFloat = 140

    /// The chart's height in the tallest layout — which is what the expanded
    /// detent is built from. Everywhere else it is flexible and takes the slack.
    static let chartHeight: CGFloat = 176
}

/// The display's bottom safe-area inset — the home indicator's height, 0 on
/// devices with a home button.
///
/// A sheet's own safe area cannot be relied on for this: the viewer puts the map
/// behind the sheet with `ignoresSafeArea`, and a fixed-height detent gives the
/// sheet content no bottom inset to inherit, so the last row lands on the home
/// indicator. Read it off the window instead, which is the one place it is
/// always correct.
enum Screen {
    @MainActor
    static var safeAreaBottom: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 0
    }
}

enum MapStyle: String, CaseIterable, Identifiable, Sendable {
    case outdoor
    case satellite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outdoor: return "Outdoor"
        case .satellite: return "Satellite"
        }
    }
}

extension MapTilerConfig {
    /// Named `styleURL(for:)` rather than shadowing the `mapStyleURL` string
    /// property, so the two MapTiler basemaps stay easy to tell apart.
    func styleURL(for style: MapStyle) -> URL {
        let string = style == .outdoor ? mapStyleURL : satelliteStyleURL
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid MapTiler style URL — check TILE_PROXY_BASE_URL in Secrets.xcconfig")
        }
        return url
    }
}
