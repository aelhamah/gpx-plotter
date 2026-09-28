import Foundation

/// The encoding of a tile, as a TileJSON `format` declares it.
public enum TileFormat: String, Sendable, CaseIterable {
    /// Mapbox vector tiles.
    case pbf
    case jpg
    case webp
    case png

    public var fileExtension: String { rawValue }

    /// What the loopback server has to answer a tile request with, so MapLibre
    /// decodes the bytes the way it expects to.
    public var contentType: String {
        switch self {
        case .pbf: return "application/x-protobuf"
        case .jpg: return "image/jpeg"
        case .webp: return "image/webp"
        case .png: return "image/png"
        }
    }

    public init?(pathExtension: String) {
        self.init(rawValue: pathExtension.lowercased())
    }

    /// Rough bytes per tile at a zoom, for a source that was not measured.
    ///
    /// A fallback only: the tile sets a style actually names differ by two orders
    /// of magnitude, so `TileSourceSize` is what the app estimates with. These
    /// are the medians of the measured MapTiler tilesets, rounded.
    public func approximateBytes(atZoom zoom: Int) -> Int {
        switch self {
        case .pbf:
            return [12: 12_000, 13: 16_000, 14: 22_000, 15: 30_000, 16: 40_000][zoom] ?? 20_000
        case .webp, .png:
            return [12: 210_000, 13: 140_000, 14: 85_000, 15: 60_000, 16: 40_000][zoom] ?? 100_000
        case .jpg:
            return [12: 65_000, 13: 72_000, 14: 75_000, 15: 90_000, 16: 110_000][zoom] ?? 80_000
        }
    }
}

/// Measured bytes per tile, by MapTiler source and zoom.
///
/// Averages from a real corridor download over the Maroon Bells loop at z12–z14,
/// not guesses. The tile sets a style needs differ wildly — `outdoor` is a few
/// KB of geometry, `contours` is a hundred KB of elevation lines, and the
/// Terrain-RGB DEM is 200 KB a tile at z12 — so one average per format would
/// promise either a 1 MB download that delivers 4, or the reverse. This figure
/// is what the user reads before committing to a download.
///
/// The keys are MapTiler's style source ids. `terrain` is the app's own name
/// for the DEM source it adds to the style (`AppConfig.demSource`), which
/// resolves to MapTiler's `terrain-rgb-v2`.
public enum TileSourceSize {
    /// source → zoom → measured average bytes per tile.
    public static let measured: [String: [Int: Int]] = [
        // Basemap geometry, with neither labels nor relief.
        "outdoor": [12: 5_000, 13: 3_000, 14: 2_000],
        // Contour lines dominate a download, not the basemap.
        "contours": [12: 120_000, 13: 180_000, 14: 75_000],
        // Labels and place names, over the same tiles.
        "maptiler_planet": [12: 9_000, 13: 11_000, 14: 7_000],
        "satellite": [12: 65_000, 13: 72_000, 14: 75_000],
        "terrain": [12: 210_000, 13: 140_000, 14: 85_000],
    ]

    /// Bytes to assume for one tile of `source` at `zoom`.
    ///
    /// Falls back to the format's own figure for a source that was not measured.
    public static func approximateBytes(source: String, format: TileFormat, zoom: Int) -> Int {
        measured[source]?[zoom] ?? format.approximateBytes(atZoom: zoom)
    }
}

/// Identity of one cached map tile, and everything derivable from it.
///
/// **The source name is part of the key, and it has to be.** A MapTiler style
/// carries several tile sets at the same coordinates — `outdoor` carries the
/// basemap, `contours` the contour lines, `maptiler_planet` the labels,
/// `terrain` the DEM, and the satellite style adds a raster `satellite` — and
/// every one of them is a different payload for the same `z/x/y`. A cache keyed
/// by coordinates alone answers a `contours` request with `outdoor`'s bytes, and
/// a corridor prefetch that believes it has fetched all four sources has in fact
/// fetched one and stored it four times over.
public struct TileCacheKey: Hashable, Sendable, CustomStringConvertible {
    /// The style's source id, e.g. `outdoor`.
    public let source: String
    public let z: Int
    public let x: Int
    public let y: Int
    public let format: TileFormat

    public init(source: String, z: Int, x: Int, y: Int, format: TileFormat = .pbf) {
        self.source = source
        self.z = z
        self.x = x
        self.y = y
        self.format = format
    }

    public init(tile: TileCoordinate, source: String, format: TileFormat = .pbf) {
        self.init(source: source, z: tile.z, x: tile.x, y: tile.y, format: format)
    }

    public var description: String { "\(source)/\(z)/\(x)/\(y).\(format.fileExtension)" }

    /// On-disk name. The source is in it, for the reason above.
    public var fileName: String { "\(source)_\(z)_\(x)_\(y).\(format.fileExtension)" }

    /// What the style's `tiles` template looks like, pointing at the loopback
    /// caching proxy: `/tiles/outdoor/{z}/{x}/{y}.pbf`.
    public var loopbackTemplate: String {
        "/tiles/\(source)/{z}/{x}/{y}.\(format.fileExtension)"
    }

    /// The concrete request path for this tile.
    public var loopbackPath: String { "/tiles/\(source)/\(z)/\(x)/\(y).\(format.fileExtension)" }

    /// MapTiler's own URL for this tile, from a `{z}/{x}/{y}` template.
    public func upstreamURL(template: String) -> URL? {
        URL(string: template
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)"))
    }

    /// Read a key back out of a loopback request path.
    ///
    /// Returns nil for anything that is not `/tiles/{source}/{z}/{x}/{y}.{ext}`,
    /// which is how the server tells a tile request from a style or slope one.
    public static func parse(path: String) -> TileCacheKey? {
        let pieces = path.split(separator: "/")
        guard pieces.count == 5, pieces[0] == "tiles" else { return nil }

        let name = String(pieces[4])
        guard let format = TileFormat(pathExtension: String(name.split(separator: ".").last ?? "")),
              let z = Int(pieces[2]), let x = Int(pieces[3]),
              let y = Int(name.split(separator: ".").first ?? "")
        else { return nil }

        return TileCacheKey(source: String(pieces[1]), z: z, x: x, y: y, format: format)
    }
}
