import Foundation
import RouteKit

/// Fetches MapTiler's hosted style and injects the 3D terrain block that
/// MapLibre Native has no imperative setter for.
///
/// The web app calls `map.setTerrain({ source: 'terrain', exaggeration: 1.15 })`,
/// which is a MapLibre GL **JS** API. Native's ObjC headers expose no terrain
/// setter at all, so the only way to get 3D terrain is to have
/// `"terrain": { "source": …, "exaggeration": … }` present in the style JSON
/// before the map loads it.
///
/// The style is still MapTiler's own — this patches a copy rather than
/// hand-authoring one, so the basemap keeps tracking MapTiler's design. The DEM
/// source is added with an inline `tiles` template rather than a TileJSON `url`
/// for the same reason the web app's own source works: a `raster-dem` source
/// built from a TileJSON document has to be resolved before the terrain block
/// can reference it, and MapLibre Native does not resolve it for a style it
/// loaded from a URL.
///
/// Results are cached per (style, terrain) pair, so toggling terrain does not
/// refetch MapTiler's style.
actor StyleBuilder {
    /// Terrain exaggeration, matching the web app's `setTerrain` call.
    static let terrainExaggeration = 1.15

    private let session: URLSession
    private let config: MapTilerConfig?
    private var cache: [String: Data] = [:]
    private var inFlight: [String: Task<Data, Error>] = [:]

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
        if let existing = inFlight[key] { return try? await existing.value }

        let task = Task<Data, Error> { [config, session] in
            guard let url = URL(string: Self.styleURLString(for: style, config: config)) else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: url)
            request.setValue(MapNetworkIdentity.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(MapNetworkIdentity.versionHeader, forHTTPHeaderField: "X-GPXNav-Version")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return try Self.patching(data, terrain: terrain, config: config)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            let patched = try await task.value
            cache[key] = patched
            return patched
        } catch {
            print("StyleBuilder failed for \(key): \(error)")
            return nil
        }
    }

    private static func styleURLString(for style: MapStyle, config: MapTilerConfig) -> String {
        switch style {
        case .outdoor: config.mapStyleURL
        case .satellite: config.satelliteStyleURL
        }
    }

    /// Add the DEM source, and the terrain block when it is wanted.
    static func patching(_ data: Data, terrain: Bool, config: MapTilerConfig) throws -> Data {
        guard var style = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        var sources = style["sources"] as? [String: Any] ?? [:]
        // Name it `terrain` to match the web app's source id, so the relief
        // layer and the terrain block refer to the same thing.
        sources["terrain"] = [
            "type": "raster-dem",
            "tiles": [config.terrainTileURL],
            "tileSize": 512,
            "maxzoom": MapLayers.demMaxZoom,
            "encoding": "mapbox",
        ]
        style["sources"] = sources

        if terrain {
            style["terrain"] = [
                "source": "terrain",
                "exaggeration": terrainExaggeration,
            ]
        } else {
            style.removeValue(forKey: "terrain")
        }

        return try JSONSerialization.data(withJSONObject: style)
    }
}
