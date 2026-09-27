import Foundation

public struct TileCoordinate: Equatable, Hashable, Sendable, Codable {
    public var z: Int
    public var x: Int
    public var y: Int

    public init(z: Int, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }

    public var key: String { "\(z)/\(x)/\(y)" }
}

public struct TileBounds: Equatable, Sendable {
    public var west: Double
    public var south: Double
    public var east: Double
    public var north: Double

    public init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }
}

/// Web-Mercator tile math shared by the DEM store, the slope raster, and the
/// offline prefetch. Ported from the tile helpers in `web/src/dem.ts`.
public enum TileMath {
    /// Equatorial circumference of the Web Mercator world, in meters.
    public static let circumferenceMeters = 40_075_016.686

    public static let tileSizePixels = 256

    /// Fractional tile coordinates for a lng/lat: the integer part is the tile,
    /// the fraction is the position within it.
    public static func fractionalTile(lon: Double, lat: Double, zoom: Int) -> (x: Double, y: Double) {
        let world = Double(tileSizePixels) * pow(2, Double(zoom))
        let sinLat = sin(lat * .pi / 180)
        return (
            x: ((lon + 180) / 360) * world / Double(tileSizePixels),
            y: (0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * .pi)) * world / Double(tileSizePixels)
        )
    }

    public static func tile(lon: Double, lat: Double, zoom: Int) -> TileCoordinate {
        let fractional = fractionalTile(lon: lon, lat: lat, zoom: zoom)
        return TileCoordinate(
            z: zoom,
            x: Int(fractional.x.rounded(.down)),
            y: Int(fractional.y.rounded(.down))
        )
    }

    /// North-west corner of a tile.
    public static func northWest(of tile: TileCoordinate) -> Coordinate {
        let n = .pi - 2 * .pi * Double(tile.y) / pow(2, Double(tile.z))
        return Coordinate(
            lat: atan(sinh(n)) * (180 / .pi),
            lon: (Double(tile.x) / pow(2, Double(tile.z))) * 360 - 180
        )
    }

    public static func bounds(of tile: TileCoordinate) -> TileBounds {
        let nw = northWest(of: tile)
        let ne = northWest(of: TileCoordinate(z: tile.z, x: tile.x + 1, y: tile.y))
        let sw = northWest(of: TileCoordinate(z: tile.z, x: tile.x, y: tile.y + 1))
        return TileBounds(
            west: nw.lon,
            south: sw.lat,
            east: ne.lon,
            north: nw.lat
        )
    }

    /// Centre point of a tile — what the offline corridor test measures from.
    public static func center(of tile: TileCoordinate) -> Coordinate {
        let b = bounds(of: tile)
        return Coordinate(lat: (b.north + b.south) / 2, lon: (b.west + b.east) / 2)
    }

    /// Ground meters covered by one tile edge at the equator, independent of latitude.
    public static func groundSizeMeters(zoom: Int) -> Double {
        circumferenceMeters / pow(2, Double(zoom))
    }

    /// Horizontal meters covered by one 256px tile pixel at the given mid-latitude and zoom.
    public static func metersPerPixel(zoom: Int, midLatitude: Double) -> Double {
        groundSizeMeters(zoom: zoom) * cos(midLatitude * .pi / 180)
    }

    /// Meters per DEM pixel for a tile at `zoom`, whose top edge is at `tileNorthLat`.
    public static func metersPerPixel(zoom: Int, tileNorthLat: Double, pixelWidth: Int) -> Double {
        let midLat = tileNorthLat + (180 / pow(2, Double(zoom))) / 2
        return metersPerPixel(zoom: zoom, midLatitude: midLat) / Double(pixelWidth)
    }
}