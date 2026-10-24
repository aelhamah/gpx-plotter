import Foundation

/// Which vector tiles a snap query needs. No I/O here; `SnapEngine` fetches.
///
/// Port of the web app's `web/src/snapTiles.ts`.
///
/// Snapping reads the *same* tiles the basemap draws, at the zoom the map is
/// showing, for two reasons:
///
///  - Zoom 13 is the worst available choice. The planet tileset generalises and
///    drops minor paths as zoom falls, so a trail that is plainly visible on the
///    map often has no geometry at all in a z13 tile. Measured on a recorded
///    12.5 km hike, snapping against z13 found *no* trail at all for 39 of 83
///    taps taken along a trail that is mapped end to end; at z15 it found one
///    for 75 of 83. Reading at the map's zoom also puts the snapped point on the
///    line the user is actually looking at, instead of a coarsely generalised
///    stand-in for it.
///  - The zoom has a ceiling. MapTiler's `outdoor` tileset stops at z14 and the
///    planet (`v3`) tileset at z15; anything deeper is an HTTP 400, so each
///    source is clamped to its own maximum rather than to a shared one.
public enum SnapTiles {
    /// Snapping needs a zoom where the tilesets still carry paths; z12 emits no
    /// path-like classes.
    public static let snapMinZoom = 14
    /// Deepest zoom either snap tileset serves (planet z15, outdoor z14).
    public static let snapMaxZoom = 15

    public enum TilesetId: String, Equatable, Sendable, CaseIterable {
        case outdoor
        case planet

        /// Highest zoom the tileset actually serves. A deeper request is an
        /// HTTP 400.
        public var maxZoom: Int {
            switch self {
            case .outdoor: return 14
            case .planet: return 15
            }
        }

        /// The `TileCache` source name the basemap style caches this tileset
        /// under. The style's planet source is named `maptiler_planet`, while
        /// the snap URL template is `/tiles/v3/...` — same bytes, different
        /// name, and the offline cache only knows the style's.
        public var cacheSourceName: String {
            switch self {
            case .outdoor: return "outdoor"
            case .planet: return "maptiler_planet"
            }
        }
    }

    static let earthCircumference = 40_075_016.686

    /// The zoom to snap at for a given map zoom: the map's own zoom, rounded and
    /// clamped into the range the snap tilesets can serve.
    ///
    /// Rounded rather than floored so that panning at a fractional zoom reuses
    /// the tile cache instead of refetching on every fractional step. Below
    /// `snapMinZoom` the basemap itself is dropping paths, so snapping anyway
    /// would move a point onto something the user cannot see.
    public static func snapZoom(for mapZoom: Double) -> Int {
        guard mapZoom.isFinite else { return snapMinZoom }
        return max(snapMinZoom, min(snapMaxZoom, Int(mapZoom.rounded())))
    }

    /// The zoom a single tileset can actually serve at or below `zoom`.
    public static func zoom(forTileset tileset: TilesetId, at zoom: Int) -> Int {
        max(0, min(zoom, tileset.maxZoom))
    }

    /// Ground resolution at a latitude and zoom: meters per tile. Web Mercator
    /// stretches longitude, so this is the east-west extent of a tile there.
    public static func tileSpanMeters(lat: Double, zoom: Int) -> Double {
        let clamped = max(-85.05112878, min(85.05112878, lat))
        return (earthCircumference * cos(clamped * .pi / 180)) / pow(2, Double(zoom))
    }

    public struct TileAddress: Equatable, Hashable, Sendable {
        public var x: Int
        public var y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    struct FractionalTile {
        var x: Int
        var y: Int
        /// Fractional tile coordinate, so how far the point sits from each edge
        /// is known.
        var fx: Double
        var fy: Double
    }

    static func fractionalTile(lng: Double, lat: Double, zoom: Int) -> FractionalTile {
        let n = pow(2, Double(zoom))
        let sinLat = sin(lat * .pi / 180)
        let x = (lng + 180) / 360 * n
        let y = (0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * .pi)) * n
        return FractionalTile(x: Int(x.rounded(.down)), y: Int(y.rounded(.down)), fx: x.truncatingRemainder(dividingBy: 1), fy: y.truncatingRemainder(dividingBy: 1))
    }

    /// Whether a radius query centred in one tile reaches across an edge.
    ///
    /// Comparing the radius with the whole tile width would round every query
    /// up to a full 3×3 ring, turning the common case — a point well inside a
    /// z15 tile snapping at 40 m — into nine fetches per source instead of one.
    /// Measuring against the actual distance to each edge keeps the common case
    /// at one tile and still adds the neighbour whenever the radius really does
    /// reach it.
    static func crosses(_ radius: Double, offset: Double, span: Double) -> (negative: Bool, positive: Bool) {
        (negative: radius > offset * span, positive: radius > (1 - offset) * span)
    }

    /// Every tile that can hold a point within `radiusMeters` of (lng, lat).
    ///
    /// A single tile clips a radius query at the tile edge, so a snap near a
    /// boundary silently loses candidates. This returns the containing tile plus
    /// whichever neighbours the radius actually reaches. The result is a square
    /// ring rather than an exact disc: it can pull in a diagonal neighbour that
    /// the radius does not quite reach, which costs one cheap tile and is far
    /// better than dropping a real candidate.
    public static func tilesNear(lng: Double, lat: Double, zoom: Int, radiusMeters: Double) -> [TileAddress] {
        guard lng.isFinite, lat.isFinite else { return [] }
        let span = tileSpanMeters(lat: lat, zoom: zoom)
        guard span > 0 else { return [] }
        let radius = max(0, radiusMeters)
        let centre = fractionalTile(lng: lng, lat: lat, zoom: zoom)
        let maxIndex = Int(pow(2, Double(zoom))) - 1
        let dx = crosses(radius, offset: centre.fx, span: span)
        let dy = crosses(radius, offset: centre.fy, span: span)

        var tiles: [TileAddress] = []
        var offsetY = dy.negative ? -1 : 0
        while offsetY <= (dy.positive ? 1 : 0) {
            let y = centre.y + offsetY
            if y >= 0 && y <= maxIndex {
                var offsetX = dx.negative ? -1 : 0
                while offsetX <= (dx.positive ? 1 : 0) {
                    let x = centre.x + offsetX
                    if x >= 0 && x <= maxIndex {
                        tiles.append(TileAddress(x: x, y: y))
                    }
                    offsetX += 1
                }
            }
            offsetY += 1
        }
        return tiles
    }
}
