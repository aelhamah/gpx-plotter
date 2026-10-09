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
        return hasMapTilerKey ? .mapTiler : .mapLibreDemo
    }

    /// True when the demo basemap is only up because the key never arrived.
    ///
    /// Falling back silently is how a missing `MaptilerAPIKey` once looked
    /// exactly like a working demo run: the map drew, and only the disabled
    /// terrain/offline controls hinted that the key was missing. This flag lets
    /// the UI say so out loud.
    static var isKeyMissingFallback: Bool {
        styleSource == .mapLibreDemo && !isDemoRequested
    }

    static var hasMapTilerKey: Bool { !maptilerAPIKey.isEmpty }

    /// Config for the DEM tile store. `nil` on the demo basemap, because the
    /// public demo tileset ships no Terrain-RGB endpoint we can authenticate.
    static var terrainConfig: MapTilerConfig? {
        hasMapTilerKey ? MapTilerConfig(apiKey: maptilerAPIKey) : nil
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
        guard hasMapTilerKey else { return demoStyleURL }
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

    /// Height of the sheet's short detent: the expand affordance and the figures.
    ///
    /// The content is 28 (chevron) + 88 (two rows of figures) + 34 (home indicator)
    /// = 150, and the detent has to **clear** it: a sheet taller than its detent
    /// does not scroll, it compresses from the top, so the first row is what
    /// disappears. That is how the chevron once measured 22pt in a layout pass and
    /// still painted as a 3pt sliver.
    ///
    /// 132 is below the content on purpose. The sheet is sized by whichever is
    /// larger, so a detent under the content's natural height lands the sheet on
    /// the content exactly and the slack becomes the home-indicator inset instead
    /// of a visible band. Verified on the simulator: 132 renders a 143pt sheet
    /// against 150pt of content, and 150 rendered a 175pt sheet with 65pt of
    /// nothing under the figures.
    static let statsOnlyPanelHeight: CGFloat = 132

    /// Height of the sheet's tall detent: the stats rows, the profile, the slope
    /// legend, and the offline row, and nothing more.
    ///
    /// Sized to the content rather than to the screen, on purpose. `.large` put
    /// the sheet over almost the whole display, which is the opposite of what a
    /// profile is for — scrubbing it traces the position on the map, so the map
    /// has to stay visible while the sheet is up.
    ///
    /// 460 pt is the content: chevron 28 + two stat rows 88 + key warning 22 + chart
    /// 170 + scrub caption 20 + legend 44 + offline row 54 + home indicator 34.
    /// 464 leaves a few points of slack. An earlier 466 left a visible band of
    /// dead space under the offline row and a 396 clipped the top stats row behind
    /// the sheet's rounded corner. Same ceiling as `statsOnlyPanelHeight`: the
    /// detent has to clear the content or the sheet eats its own first row.
    ///
    /// The content is not fixed — with a MapTiler key the warning goes away, and
    /// the scrub caption after the first drag — so this is sized for the tallest
    /// layout and the slack collects harmlessly at the bottom.
    static let expandedPanelHeight: CGFloat = 464

    /// Whether 3D terrain can be switched on. Needs a key: the demo basemap has
    /// no Terrain-RGB source to point the terrain block at.
    static var canUseTerrain3D: Bool { hasMapTilerKey }

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

    private static var maptilerAPIKey: String {
        let key = Bundle.main.object(forInfoDictionaryKey: "MaptilerAPIKey") as? String
        return key?.isEmpty == false ? key! : ""
    }

    /// Shared geocoding client, or `nil` without a key.
    static let geocodingClient: GeocodingClient? = hasMapTilerKey
        ? GeocodingClient(apiKey: maptilerAPIKey)
        : nil

    /// Why search is unavailable, or nil when it works.
    static var searchLimitation: String? {
        geocodingClient == nil
            ? "Search needs a MapTiler key. The demo basemap has no geocoder."
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
            return "MapTiler key missing — demo tiles"
        }
        switch styleSource {
        case .mapTiler:
            return "MapTiler \(hasMapTilerKey ? "key loaded" : "key missing")"
        case .mapLibreDemo:
            return "MapLibre demo tiles — no MapTiler key in use"
        }
    }

    /// Why the app is on demo tiles despite no `-demoTiles` flag, or nil when
    /// that is not the case.
    static var keyProblemDescription: String? {
        guard isKeyMissingFallback else { return nil }
        return "No MapTiler key reached the app, so it fell back to the demo basemap. Check MAPTILER_API_KEY in Secrets.xcconfig — the key must be a real entry in GPXNav/Info.plist, because Xcode drops custom INFOPLIST_KEY_* names."
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
            preconditionFailure("Invalid MapTiler style URL — check MAPTILER_API_KEY in Secrets.xcconfig")
        }
        return url
    }
}
