import Foundation
import RouteKit

/// Fetches MapTiler's hosted style, resolves its basemap sources, and rewrites
/// it for what MapLibre Native cannot do on its own.
///
/// Three rewrites, all forced by Native's missing APIs:
///
/// - **3D terrain.** The web app calls `map.setTerrain({ source, exaggeration })`,
///   a MapLibre GL **JS** API. Native's ObjC headers expose no terrain setter,
///   so `"terrain": { … }` has to be in the style JSON before the map loads it.
/// - **Cached tiles.** MapTiler's sources are all TileJSON `url`s, which
///   MapLibre resolves for a live map but which leave us no seam to intercept a
///   tile. They are resolved here and repointed at the loopback cache, so every
///   basemap request passes through disk. That is what makes an offline map
///   possible at all — see `TileCache`.
/// - **Cached elevation.** The DEM source is repointed at the loopback for the
///   same reason: hillshade and 3D terrain read it straight from MapTiler
///   otherwise, and neither survives being offline.
///
/// The basemap is still MapTiler's own; only these things are changed.
actor StyleBuilder {
    /// Terrain exaggeration, matching the web app's `setTerrain` call.
    static let terrainExaggeration = 1.15

    private let session: URLSession
    private let config: MapTilerConfig?
    private var cache: [String: Data] = [:]
    private var inFlight: [String: Task<(Data, ResolvedSources), Error>] = [:]
    /// Source id → MapTiler's own tile URL template, from that source's
    /// TileJSON. The loopback server substitutes coordinates into it on a miss.
    private var upstreamTemplates: [String: String] = [:]
    private var sources: [String: BasemapSource] = [:]

    init(config: MapTilerConfig?) {
        self.config = config
        let configuration = URLSessionConfiguration.default
        // The style is fetched by us rather than by MapLibre, so it needs the
        // allowlisted user-agent set explicitly instead of coming from
        // MLNNetworkConfiguration.
        configuration.httpAdditionalHeaders = [
            "User-Agent": MapNetworkIdentity.userAgent,
            "X-GPXNav-Version": MapNetworkIdentity.versionHeader,
        ]
        self.session = URLSession(configuration: configuration)
    }

    /// The style JSON to hand MapLibre, or nil when there is no MapTiler key.
    func style(for style: MapStyle, terrain: Bool) async -> Data? {
        guard let config else { return nil }
        let key = "\(style.rawValue)-\(terrain)"
        if let cached = cache[key] { return cached }
        if let existing = inFlight[key] { return try? await existing.value.0 }

        let task = Task<(Data, ResolvedSources), Error> { [config, session] in
            let raw = try await Self.fetchStyle(for: style, config: config, session: session)
            let resolved = try await Self.resolveTileSources(in: raw, session: session)
            let patched = try Self.patching(
                resolved.style,
                terrain: terrain,
                formats: resolved.sources.mapValues(\.format)
            )
            return (patched, resolved.sources)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            let (patched, found) = try await task.value
            upstreamTemplates.merge(found.mapValues(\.upstreamTemplate)) { _, new in new }
            sources.merge(found) { _, new in new }
            // The DEM source is ours, not the style's, so its upstream is known
            // here rather than from a TileJSON fetch. Both the loopback's
            // `/tiles/terrain/…` route and the slope generator read through it.
            upstreamTemplates[AppConfig.demSource] = config.terrainTileURL
            sources[AppConfig.demSource] = BasemapSource(
                name: AppConfig.demSource,
                format: .webp,
                upstreamTemplate: config.terrainTileURL
            )
            cache[key] = patched
            return patched
        } catch {
            print("StyleBuilder failed for \(key): \(error)")
            return nil
        }
    }

    /// MapTiler's tile URL template for a basemap source, or nil if the style
    /// has not been built yet.
    func upstreamTemplate(forSource source: String) -> String? {
        upstreamTemplates[source]
    }

    /// Every tile set the loaded style needs, so the corridor download covers
    /// what the map actually asks for.
    ///
    /// Read from the style rather than hardcoded, because the two basemaps
    /// differ: `outdoor-v2` has three vector sources, `satellite-v4` swaps one
    /// for a raster, and the elevation source is the same in both.
    func basemapSources() -> [BasemapSource] {
        sources.values.sorted { $0.name < $1.name }
    }

    // MARK: - Fetching

    private static func styleURLString(for style: MapStyle, config: MapTilerConfig) -> String {
        switch style {
        case .outdoor: config.mapStyleURL
        case .satellite: config.satelliteStyleURL
        }
    }

    private static func fetchStyle(
        for style: MapStyle,
        config: MapTilerConfig,
        session: URLSession
    ) async throws -> [String: Any] {
        guard let url = URL(string: styleURLString(for: style, config: config)) else {
            throw URLError(.badURL)
        }
        let data = try await fetch(url: url, session: session)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return json
    }

    /// Resolve every TileJSON-backed source into an inline `tiles` array, and
    /// return the upstream template and format for each.
    ///
    /// Both vector and raster sources go through here: the satellite basemap is
    /// a raster tileset, and an offline map that cached the labels but not the
    /// imagery under them would be a map of nowhere. The zoom range comes from
    /// the TileJSON and is kept; only the URL is repointed. A source that fails
    /// to resolve is left as MapTiler sent it, so one bad TileJSON cannot take
    /// the whole style down.
    private static func resolveTileSources(
        in style: [String: Any],
        session: URLSession
    ) async throws -> (style: [String: Any], sources: ResolvedSources) {
        var resolved = style
        guard var rawSources = resolved["sources"] as? [String: Any] else {
            return (resolved, [:])
        }
        var found: ResolvedSources = [:]

        for (id, raw) in rawSources {
            guard var source = raw as? [String: Any],
                  let type = source["type"] as? String,
                  type == "vector" || type == "raster",
                  let tileJSONURL = source["url"] as? String,
                  let url = URL(string: tileJSONURL)
            else { continue }

            guard let data = try? await fetch(url: url, session: session),
                  let tileJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let templates = tileJSON["tiles"] as? [String], let first = templates.first
            else { continue }

            source["tiles"] = [first]
            if let minzoom = tileJSON["minzoom"] { source["minzoom"] = minzoom }
            if let maxzoom = tileJSON["maxzoom"] { source["maxzoom"] = maxzoom }
            if let bounds = tileJSON["bounds"] { source["bounds"] = bounds }
            source.removeValue(forKey: "url")
            rawSources[id] = source
            found[id] = BasemapSource(
                name: id,
                format: TileFormat(rawValue: (tileJSON["format"] as? String) ?? "")
                    ?? (type == "vector" ? .pbf : .png),
                upstreamTemplate: first
            )
        }

        resolved["sources"] = rawSources
        return (resolved, found)
    }

    private static func fetch(url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(MapNetworkIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(MapNetworkIdentity.versionHeader, forHTTPHeaderField: "X-GPXNav-Version")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Patching

    /// Point the tile sources at the loopback cache, and add the DEM source plus
    /// the terrain block.
    ///
    /// `formats` comes from the TileJSON resolution rather than being guessed
    /// here, because the extension is part of the loopback path: a raster
    /// source served as `.pbf` is a tile MapLibre cannot decode.
    static func patching(
        _ style: [String: Any],
        terrain: Bool,
        formats: [String: TileFormat]
    ) throws -> Data {
        var patched = style
        var sources = patched["sources"] as? [String: Any] ?? [:]

        for (id, raw) in sources {
            guard var source = raw as? [String: Any],
                  let type = source["type"] as? String,
                  type == "vector" || type == "raster"
            else { continue }
            let format = formats[id] ?? (type == "vector" ? .pbf : .png)
            source["tiles"] = [AppConfig.cachedTileURLTemplate(forSource: id, format: format)]
            source.removeValue(forKey: "url")
            sources[id] = source
        }

        // Named `terrain` to match the web app's source id, so the relief layer
        // and the terrain block refer to the same thing, and read through the
        // loopback so elevation is on disk like everything else. Inline tiles
        // rather than a TileJSON url, for the same reason the basemap sources
        // are resolved.
        sources[AppConfig.demSource] = [
            "type": "raster-dem",
            "tiles": [AppConfig.demTileURLTemplate],
            "tileSize": 512,
            "maxzoom": MapLayers.demMaxZoom,
            "encoding": "mapbox",
        ]
        patched["sources"] = sources

        if terrain {
            patched["terrain"] = [
                "source": AppConfig.demSource,
                "exaggeration": terrainExaggeration,
            ]
        } else {
            patched.removeValue(forKey: "terrain")
        }

        return try JSONSerialization.data(withJSONObject: patched)
    }
}

/// One tile set a loaded style depends on.
struct BasemapSource: Hashable, Sendable {
    /// The style's source id, which is also the loopback path segment and the
    /// prefix of its cache file.
    let name: String
    let format: TileFormat
    /// MapTiler's own `{z}/{x}/{y}` template for this tileset.
    let upstreamTemplate: String

    /// Elevation rather than map imagery. It is a different kind of tile — the
    /// loopback serves it as the `raster-dem` source, the hillshade layer reads
    /// it, and the slope generator decodes it — and it stops at z14, so a
    /// corridor download asks for it over a narrower range than the basemap.
    var isElevation: Bool { name == AppConfig.demSource }
}

/// Source id → the tile set it needs, as resolved from the style's TileJSON.
typealias ResolvedSources = [String: BasemapSource]
