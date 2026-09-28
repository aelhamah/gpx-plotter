import Foundation
import RouteKit

/// Fetches MapTiler's hosted style, resolves its basemap sources, and rewrites
/// it for what MapLibre Native cannot do on its own.
///
/// Two rewrites, both forced by Native's missing APIs:
///
/// - **3D terrain.** The web app calls `map.setTerrain({ source, exaggeration })`,
///   a MapLibre GL **JS** API. Native's ObjC headers expose no terrain setter,
///   so `"terrain": { … }` has to be in the style JSON before the map loads it.
/// - **Cached tiles.** MapTiler's sources are all TileJSON `url`s, which
///   MapLibre resolves for a live map but which leave us no seam to intercept a
///   tile. They are resolved here and repointed at the loopback cache, so every
///   basemap request passes through disk. That is what makes an offline map
///   possible at all — see `VectorTileCache`.
///
/// The basemap is still MapTiler's own; only these two things are changed.
actor StyleBuilder {
    /// Terrain exaggeration, matching the web app's `setTerrain` call.
    static let terrainExaggeration = 1.15

    private let session: URLSession
    private let config: MapTilerConfig?
    private var cache: [String: Data] = [:]
    private var inFlight: [String: Task<(Data, [String: String]), Error>] = [:]
    /// Source id → MapTiler's own tile URL template, from that source's
    /// TileJSON. The loopback server substitutes coordinates into it on a miss.
    private var upstreamTemplates: [String: String] = [:]

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

        let task = Task<(Data, [String: String]), Error> { [config, session] in
            let raw = try await Self.fetchStyle(for: style, config: config, session: session)
            let resolved = try await Self.resolveVectorSources(in: raw, session: session)
            let patched = try Self.patching(
                resolved.style,
                terrain: terrain,
                config: config
            )
            return (patched, resolved.upstreams)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            let (patched, upstreams) = try await task.value
            upstreamTemplates.merge(upstreams) { _, new in new }
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

    /// Resolve every vector source's TileJSON into an inline `tiles` array, and
    /// return the upstream template for each.
    ///
    /// The zoom range comes from the TileJSON and is kept; only the URL is
    /// repointed. A source that fails to resolve is left as MapTiler sent it, so
    /// one bad TileJSON cannot take the whole style down.
    private static func resolveVectorSources(
        in style: [String: Any],
        session: URLSession
    ) async throws -> (style: [String: Any], upstreams: [String: String]) {
        var resolved = style
        guard var sources = resolved["sources"] as? [String: Any] else {
            return (resolved, [:])
        }
        var upstreams: [String: String] = [:]

        for (id, raw) in sources {
            guard var source = raw as? [String: Any],
                  source["type"] as? String == "vector",
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
            sources[id] = source
            upstreams[id] = first
        }

        resolved["sources"] = sources
        return (resolved, upstreams)
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

    /// Point the vector sources at the loopback cache, and add the DEM source
    /// plus the terrain block.
    static func patching(
        _ style: [String: Any],
        terrain: Bool,
        config: MapTilerConfig
    ) throws -> Data {
        var patched = style
        var sources = patched["sources"] as? [String: Any] ?? [:]

        for (id, raw) in sources {
            guard var source = raw as? [String: Any],
                  source["type"] as? String == "vector"
            else { continue }
            source["tiles"] = [AppConfig.cachedTileURLTemplate(forSource: id)]
            source.removeValue(forKey: "url")
            sources[id] = source
        }

        // Named `terrain` to match the web app's source id, so the relief layer
        // and the terrain block refer to the same thing. Inline tiles rather than
        // a TileJSON url, for the same reason the basemap sources are resolved.
        sources["terrain"] = [
            "type": "raster-dem",
            "tiles": [config.terrainTileURL],
            "tileSize": 512,
            "maxzoom": MapLayers.demMaxZoom,
            "encoding": "mapbox",
        ]
        patched["sources"] = sources

        if terrain {
            patched["terrain"] = [
                "source": "terrain",
                "exaggeration": terrainExaggeration,
            ]
        } else {
            patched.removeValue(forKey: "terrain")
        }

        return try JSONSerialization.data(withJSONObject: patched)
    }
}
