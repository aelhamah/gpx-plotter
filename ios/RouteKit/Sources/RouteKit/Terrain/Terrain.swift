import Foundation
#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics
#endif

/// Maximum zoom for Terrain-RGB DEM tiles.
public let DEMMaxZoom = 14

/// Raw elevation grid from a DEM tile.
public struct TerrainTile: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var elevations: [Float]

    public init(width: Int, height: Int, elevations: [Float]) {
        self.width = width
        self.height = height
        self.elevations = elevations
    }
}

/// Client-side decoder for MapTiler Terrain-RGB tiles.
///
/// Provides two things the app previously could not do without elevation in
/// the GPX file:
/// 1. `elevationAt()` — sample terrain elevation for any lng/lat (used to fill
///    missing elevations on imported/drawn points so gain/loss/low/high and
///    max slope always populate).
/// 2. `slopeRgba()` — a colorized slope-angle raster per DEM tile so the whole
///    terrain can be shaded avalanche-style (`<20°` … `45°+`).
///
/// Elevation model: R/G/B encode `-10000 + (R*256*256 + G*256 + B) * 0.1` meters.
public enum TerrainRGB {
    /// Terrain-RGB pixel data → float32 elevations (meters):
    /// `-10000 + (R*65536 + G*256 + B) * 0.1`.
    public static func decodeElevations(_ data: [UInt8]) -> [Float] {
        let count = data.count / 4
        var elevations = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let r = Float(data[i * 4])
            let g = Float(data[i * 4 + 1])
            let b = Float(data[i * 4 + 2])
            elevations[i] = -10000 + (r * 256 * 256 + g * 256 + b) * 0.1
        }
        return elevations
    }

    /// Bilinear terrain elevation (meters) at a fractional tile position.
    public static func bilinearSample(tile: TerrainTile, fx: Double, fy: Double) -> Double? {
        let width = tile.width
        let height = tile.height
        let elevations = tile.elevations

        let x0 = max(0, min(width - 2, Int(fx)))
        let y0 = max(0, min(height - 2, Int(fy)))
        let dx = fx - Double(x0)
        let dy = fy - Double(y0)

        let at = { (ix: Int, iy: Int) -> Float in
            elevations[iy * width + ix]
        }

        let top = at(x0, y0) * Float(1 - dx) + at(x0 + 1, y0) * Float(dx)
        let bottom = at(x0, y0 + 1) * Float(1 - dx) + at(x0 + 1, y0 + 1) * Float(dx)
        return Double(top * Float(1 - dy) + bottom * Float(dy))
    }
}

/// Avalanche-style slope bands.
public enum SlopeBands {
    /// CSS color per avalanche slope band (matches the on-map slope legend).
    public static func slopeBandColorHex(_ slopeDeg: Double) -> String {
        if slopeDeg < 20 { return "#22c55e" }
        if slopeDeg < 30 { return "#eab308" }
        if slopeDeg < 35 { return "#f97316" }
        if slopeDeg < 40 { return "#ef4444" }
        if slopeDeg < 45 { return "#a855f7" }
        return "#111827"
    }

    /// RGBA color for a slope angle (alpha 0.6 for <45°, 0.67 for 45°+).
    public static func slopeBandColorRGBA(_ slopeDeg: Double) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let hex = slopeBandColorHex(slopeDeg)
        let start = hex.index(hex.startIndex, offsetBy: 1)
        let r = UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        let g = UInt8(hex[hex.index(start, offsetBy: 2)..<hex.index(start, offsetBy: 4)], radix: 16)!
        let b = UInt8(hex[hex.index(start, offsetBy: 4)..<hex.index(start, offsetBy: 6)], radix: 16)!
        let alpha: UInt8 = slopeDeg >= 45 ? 170 : 150
        return (r, g, b, alpha)
    }

    /// Colorize a DEM elevation grid by slope angle into RGBA bytes.
    ///
    /// - Parameters:
    ///   - elevations: Flat array of elevations (row-major, width × height).
    ///   - width: Tile width in pixels.
    ///   - height: Tile height in pixels.
    ///   - ppx: Meters per DEM pixel.
    ///   - step: Gradient step size (default 4, matching web version).
    /// - Returns: Flat RGBA array (4 bytes per pixel, row-major).
    public static func slopeRgba(
        elevations: [Float],
        width: Int,
        height: Int,
        ppx: Double,
        step: Int = 4
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for j in 0..<height {
            for i in 0..<width {
                let iL = max(i - step, 0)
                let iR = min(i + step, width - 1)
                let jU = max(j - step, 0)
                let jD = min(j + step, height - 1)

                let dzx = elevations[j * width + iR] - elevations[j * width + iL]
                let dzy = elevations[jD * width + i] - elevations[jU * width + i]
                let slope = atan(sqrt(Double(dzx * dzx + dzy * dzy)) / (2 * Double(step) * ppx)) * 180 / .pi

                let (r, g, b, a) = slopeBandColorRGBA(slope)
                let offset = (j * width + i) * 4
                out[offset] = r
                out[offset + 1] = g
                out[offset + 2] = b
                out[offset + 3] = a
            }
        }
        return out
    }

    /// Horizontal meters covered by one 256px tile pixel at the given mid-latitude and zoom.
    public static func metersPerPixel(zoom: Int, midLatitude: Double) -> Double {
        let circumference = 40_075_016.686
        return (circumference / pow(2, Double(zoom))) * cos(midLatitude * .pi / 180) / 256
    }
}

/// Protocol for HTTP client to allow test injection.
public protocol HTTPClient: Sendable {
    func data(from url: String) async throws -> (Data, URLResponse)
}

public struct DefaultHTTPClient: HTTPClient {
    public init() {}
    public func data(from url: String) async throws -> (Data, URLResponse) {
        guard let url = URL(string: url) else { throw URLError(.badURL) }
        return try await URLSession.shared.data(from: url)
    }
}

/// Async DEM tile store with in-memory caching.
public actor TerrainTileStore {
    private var cache: [String: TerrainTile] = [:]
    private var pending: [String: Task<TerrainTile, Error>] = [:]
    private let httpClient: HTTPClient
    private let maxCacheSize = 400
    private let config: MapTilerConfig?

    public init(httpClient: HTTPClient = DefaultHTTPClient(), config: MapTilerConfig? = nil) {
        self.httpClient = httpClient
        self.config = config
    }

    /// Fetch a DEM tile, using the cache if available.
    public func fetchTile(z: Int, x: Int, y: Int) async throws -> TerrainTile {
        let key = "\(z)/\(x)/\(y)"
        if let cached = cache[key] { return cached }

        if let inFlight = pending[key] { return try await inFlight.value }

        let task = Task { try await self.fetchTileFromNetwork(z: z, x: x, y: y) }
        pending[key] = task
        defer { pending[key] = nil }

        let tile = try await task.value
        if cache.count > maxCacheSize { cache.removeAll() }
        cache[key] = tile
        return tile
    }

    private func fetchTileFromNetwork(z: Int, x: Int, y: Int) async throws -> TerrainTile {
        guard let urlString = config?.terrainTileURL(z: z, x: x, y: y)?.absoluteString else {
            throw TerrainError.missingConfiguration
        }
        let (data, response) = try await httpClient.data(from: urlString)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TerrainError.tileFailed(key: "\(z)/\(x)/\(y)", status: http.statusCode)
        }
        return try decodeTileData(data)
    }

    /// Decode PNG/WebP image data to elevation grid.
    /// On macOS/iOS uses ImageIO; on Linux falls back to a simplified decoder.
    private func decodeTileData(_ data: Data) throws -> TerrainTile {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        let imageSource = CGImageSourceCreateWithData(data as CFData, nil)!
        let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
        let width = cgImage.width
        let height = cgImage.height

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rawData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let elevations = TerrainRGB.decodeElevations(rawData)
        return TerrainTile(width: width, height: height, elevations: elevations)
        #else
        // Fallback for platforms without ImageIO (e.g., Linux CI)
        throw GPXError.invalidXML("ImageIO not available for DEM tile decoding")
        #endif
    }

    /// Sample elevation at lng/lat from the DEM.
    public func elevationAt(lng: Double, lat: Double) async throws -> Double? {
        let z = DEMMaxZoom
        let fractional = TileMath.fractionalTile(lon: lng, lat: lat, zoom: z)
        let tx = Int(fractional.x.rounded(.down))
        let ty = Int(fractional.y.rounded(.down))
        let tile = try await fetchTile(z: z, x: tx, y: ty)
        let fx = (fractional.x - Double(tx)) * Double(tile.width)
        let fy = (fractional.y - Double(ty)) * Double(tile.height)
        return TerrainRGB.bilinearSample(tile: tile, fx: fx, fy: fy)
    }
}

public enum TerrainError: Error, LocalizedError {
    case missingConfiguration
    case tileFailed(key: String, status: Int)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "No MapTiler config — set MAPTILER_API_KEY in Secrets.xcconfig."
        case .tileFailed(let key, let status):
            return "DEM tile \(key) failed with HTTP \(status)."
        }
    }
}