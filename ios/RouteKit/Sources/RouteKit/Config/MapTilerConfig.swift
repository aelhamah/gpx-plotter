import Foundation

/// MapTiler endpoints, reached through the tile proxy.
///
/// ## Why there is no key here
///
/// This used to carry `apiKey` and put it in a query string, which put it in the
/// `.ipa` where anybody could read it. The key now lives in the proxy's secrets
/// and this type carries only the proxy's base URL — see `proxy/README.md`.
///
/// The proxy re-adds the key on the way upstream and strips it back out of the
/// styles and TileJSONs it serves, so the key never reaches this process at all.
///
/// ## Why the base URL is injected
///
/// It is a plain HTTPS origin, and it is injected rather than hardcoded so the
/// Simulator can be pointed at a locally running `wrangler dev` on
/// `http://127.0.0.1:8787` — which is also the only way to develop against the
/// proxy from a network that cannot reach `*.workers.dev`.
public struct MapTilerConfig: Equatable, Sendable {
    /// Base URL of the tile proxy, with no trailing slash.
    public var baseURL: String

    public init(baseURL: String) {
        // Normalised once, here, so no call site has to remember. A trailing
        // slash would produce `//maps/...`, which the proxy's allowlist treats
        // as a different path and answers 404 to.
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }

    public var mapStyleURL: String {
        "\(baseURL)/maps/outdoor-v2/style.json"
    }

    public var satelliteStyleURL: String {
        "\(baseURL)/maps/satellite-v4/style.json"
    }

    public var terrainURL: String {
        "\(baseURL)/tiles/terrain-rgb-v2/tiles.json"
    }

    public var terrainTileURL: String {
        "\(baseURL)/tiles/terrain-rgb-v2/{z}/{x}/{y}.png"
    }

    public func terrainTileURL(z: Int, x: Int, y: Int) -> URL? {
        URL(string: terrainTileURL
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)"))
    }

    /// Marked trail/routing vector tiles ("trail" layer) used to snap drawn
    /// points onto trails. Mirrors the web app's `OUTDOOR_TILE_URL`.
    public var outdoorTileURL: String {
        "\(baseURL)/tiles/outdoor/{z}/{x}/{y}.pbf"
    }

    /// OpenMapTiles-planet vector tiles ("transportation" and "mountain_peak"
    /// layers) used to snap waypoints onto peaks and ordinary paths onto the
    /// trail network. Mirrors the web app's `PLANET_TILE_URL`.
    public var planetTileURL: String {
        "\(baseURL)/tiles/v3/{z}/{x}/{y}.pbf"
    }

    /// One concrete tile URL for a template above (`{z}/{x}/{y}` substituted).
    public func tileURL(_ template: String, z: Int, x: Int, y: Int) -> URL? {
        URL(string: template
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)"))
    }

    public static let defaultCenter = Coordinate(lat: 39.5, lon: -106.5)
    public static let defaultZoom = 8.0
}