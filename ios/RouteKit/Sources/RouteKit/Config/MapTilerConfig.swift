import Foundation

/// MapTiler endpoints, ported from `web/src/config.ts`.
///
/// The key ships inside the app bundle (unlike the web app, where it is
/// build-time), so it is passed in rather than read from the environment.
/// Restrict it by bundle ID in the MapTiler dashboard.
public struct MapTilerConfig: Equatable, Sendable {
    public var apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    private var key: String {
        // Matches encodeURIComponent in web/src/geocode.ts: only unreserved characters survive.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return apiKey.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    public var mapStyleURL: String {
        "https://api.maptiler.com/maps/outdoor-v2/style.json?key=\(key)"
    }

    public var satelliteStyleURL: String {
        "https://api.maptiler.com/maps/satellite-v4/style.json?key=\(key)"
    }

    public var terrainURL: String {
        "https://api.maptiler.com/tiles/terrain-rgb-v2/tiles.json?key=\(key)"
    }

    public var terrainTileURL: String {
        "https://api.maptiler.com/tiles/terrain-rgb-v2/{z}/{x}/{y}.png?key=\(key)"
    }

    public func terrainTileURL(z: Int, x: Int, y: Int) -> URL? {
        URL(string: terrainTileURL
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)"))
    }

    public static let defaultCenter = Coordinate(lat: 39.5, lon: -106.5)
    public static let defaultZoom = 8.0
}