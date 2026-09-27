import Foundation
import RouteKit

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

    static func styleURL(for style: MapStyle) -> URL {
        // Debug override: point the app at a local server to inspect the exact
        // request headers iOS sends. Set GPXNAV_STYLE_URL when launching.
        if let override = ProcessInfo.processInfo.environment["GPXNAV_STYLE_URL"],
           let url = URL(string: override) {
            return url
        }
        switch styleSource {
        case .mapTiler:
            return MapTilerConfig(apiKey: maptilerAPIKey).styleURL(for: style)
        case .mapLibreDemo:
            return URL(string: "https://demotiles.maplibre.org/style.json")!
        }
    }

    /// DEM tiles for relief shading.
    static var terrainTileURL: String {
        switch styleSource {
        case .mapTiler:
            return MapTilerConfig(apiKey: maptilerAPIKey).terrainTileURL
        case .mapLibreDemo:
            // Terrarium-encoded demo terrain. `MLNRasterDEMSource` documents
            // support for the Mapbox Terrain-RGB encoding only, so relief is
            // expected to stay blank on this basemap — it is here so the wiring
            // can be exercised, not to prove the encoding.
            return "https://demotiles.maplibre.org/terrain-tiles/{z}/{x}/{y}.png"
        }
    }

    private static var maptilerAPIKey: String {
        let key = Bundle.main.object(forInfoDictionaryKey: "MaptilerAPIKey") as? String
        return key?.isEmpty == false ? key! : ""
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

    /// Zoom range downloaded for offline use, per the plan (§8).
    ///
    /// Capped at z14 because that is the highest zoom MapTiler's `outdoor-v2`
    /// style serves; asking for z15–16 would only ever produce empty tiles.
    static let offlineZoomRange = 12...14

    /// Whether `MLNOfflineStorage` packs can be used at all.
    ///
    /// False on MapLibre Native 6.31.0. `addPack` succeeds, but the pack never
    /// leaves `Inactive` and reports zero expected resources, so no tile is ever
    /// requested. Verified against MapTiler's TileJSON-only style and the same
    /// style rewritten with inline `tiles`, and for both polygon and bounding-box
    /// regions — so it is not the style, the zoom range, or the region shape.
    /// Offline is deferred until this is resolved; see docs/ios-plan.md §8.
    static let isOfflinePackDownloadSupported = false

    /// Whether an offline pack can be downloaded at all.
    ///
    /// The public demo tileset stops at z6, so a z12–14 corridor has nothing to
    /// fetch even once packs work.
    static var canDownloadOffline: Bool {
        isOfflinePackDownloadSupported && styleSource == .mapTiler
    }

    /// Why offline download is unavailable, or nil when it works.
    static var offlineLimitation: String? {
        guard canDownloadOffline else {
            if styleSource == .mapLibreDemo {
                return "Offline download needs a basemap that serves z\(offlineZoomRange.lowerBound)–\(offlineZoomRange.upperBound). The demo tileset stops at z6, so there is nothing to download."
            }
            return "Offline download is not available yet: MapLibre accepts the corridor pack but never reports any downloadable tiles, so the pack would stay at 0%. See docs/ios-plan.md §8."
        }
        return nil
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
