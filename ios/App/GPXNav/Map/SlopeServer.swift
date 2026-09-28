import Foundation
import Network
import RouteKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Loopback HTTP server for the two things MapLibre Native cannot be given
/// directly.
///
/// - `GET /slope/{z}/{x}/{y}.png` — slope rasters. Native has no equivalent of
///   the web app's `addProtocol('slope', …)`: `MLNMapViewDelegate`'s tile
///   callback is observational only, so it cannot supply data. Serving the same
///   PNGs over loopback mirrors `addProtocol` almost one-to-one and works inside
///   offline packs too.
/// - `GET /style.json?style=…&terrain=…` — MapTiler's style with the 3D terrain
///   block injected, because Native has no `setTerrain` equivalent either.
///
/// Both ride the one listener rather than opening a second port.
final class SlopeServer: @unchecked Sendable {
    private let listener: NWListener
    private let terrainStore: TerrainTileStore
    private let styleBuilder: StyleBuilder
    private let tileCache: VectorTileCache
    private let port: NWEndpoint.Port

    init(
        terrainStore: TerrainTileStore,
        styleBuilder: StyleBuilder,
        tileCache: VectorTileCache,
        port: UInt16
    ) throws {
        self.terrainStore = terrainStore
        self.styleBuilder = styleBuilder
        self.tileCache = tileCache
        self.port = NWEndpoint.Port(rawValue: port) ?? 8080
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters, on: self.port)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
            connection.start(queue: .global(qos: .utility))
        }
        listener.start(queue: .global(qos: .utility))
        print("SlopeServer listening on http://127.0.0.1:\(port.rawValue)")
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Request handling

    private func handle(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            if let (source, key) = Self.parseTileRequest(request) {
                Task { await self.serveVectorTile(source: source, key: key, to: connection) }
                return
            }
            if let query = Self.parseStyleRequest(request) {
                Task { await self.serveStyle(query: query, to: connection) }
                return
            }
            guard let (z, x, y) = Self.parse(request) else {
                self.respond(to: connection, status: 404, type: "text/plain", body: Data("not found".utf8))
                return
            }
            Task { await self.serve(z: z, x: x, y: y, to: connection) }
        }
    }

    /// `GET /slope/{z}/{x}/{y}.png` → tile coordinates.
    static func parse(_ request: String) -> (z: Int, x: Int, y: Int)? {
        guard let line = request.split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }

        let path = String(parts[1])
        let pieces = path.split(separator: "/")
        guard pieces.count == 4, pieces[0] == "slope" else { return nil }
        guard pieces[3].hasSuffix(".png"),
              let z = Int(pieces[1]), let x = Int(pieces[2]),
              let y = Int(pieces[3].dropLast(4))
        else { return nil }
        return (z, x, y)
    }

    /// `GET /tiles/{z}/{x}/{y}.pbf` → a basemap vector tile.
    static func parseTileRequest(_ request: String) -> (source: String, key: VectorTileCache.Key)? {
        guard let line = request.split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }

        // /tiles/{source}/{z}/{x}/{y}.pbf — the source is in the path because
        // the basemap's vector sources are different tile sets.
        let pieces = String(parts[1]).split(separator: "/")
        guard pieces.count == 5, pieces[0] == "tiles" else { return nil }
        let name = String(pieces[4])
        guard name.hasSuffix(".pbf"),
              let z = Int(pieces[2]), let x = Int(pieces[3]), let y = Int(name.dropLast(4))
        else { return nil }
        return (String(pieces[1]), VectorTileCache.Key(z: z, x: x, y: y))
    }

    /// Serve a vector tile from disk, fetching through to MapTiler on a miss.
    ///
    /// This is the seam that makes offline work at all: the style's basemap
    /// sources point here, so a cached tile never leaves the device, and looking
    /// at an area warms the cache as a side effect.
    private func serveVectorTile(
        source: String,
        key: VectorTileCache.Key,
        to connection: NWConnection
    ) async {
        guard let template = await styleBuilder.upstreamTemplate(forSource: source) else {
            respond(to: connection, status: 404, type: "text/plain", body: Data("no basemap".utf8))
            return
        }
        let path = template
            .replacingOccurrences(of: "{z}", with: "\(key.z)")
            .replacingOccurrences(of: "{x}", with: "\(key.x)")
            .replacingOccurrences(of: "{y}", with: "\(key.y)")
        guard let upstream = URL(string: path) else {
            respond(to: connection, status: 404, type: "text/plain", body: Data("bad upstream".utf8))
            return
        }
        do {
            let data = try await tileCache.data(for: key) { _ in
                var request = URLRequest(url: upstream)
                request.setValue(MapNetworkIdentity.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue(MapNetworkIdentity.versionHeader, forHTTPHeaderField: "X-GPXNav-Version")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw VectorTileCache.CacheError.upstreamFailed(http.statusCode)
                }
                return data
            }
            respond(to: connection, status: 200, type: "application/x-protobuf", body: data)
        } catch {
            respond(to: connection, status: 502, type: "text/plain", body: Data("\(error)".utf8))
        }
    }

    /// `GET /style.json?style=outdoor&terrain=1` → the patched style JSON.
    static func parseStyleRequest(_ request: String) -> [URLQueryItem]? {
        guard let line = request.split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }

        let target = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1" + target),
              components.path == "/style.json"
        else { return nil }
        return components.queryItems
    }

    private func serveStyle(query: [URLQueryItem], to connection: NWConnection) async {
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value
        }
        let style: MapStyle = value("style") == "satellite" ? .satellite : .outdoor
        let terrain = value("terrain") == "1"

        guard let json = await styleBuilder.style(for: style, terrain: terrain) else {
            respond(to: connection, status: 502, type: "text/plain", body: Data("no style".utf8))
            return
        }
        respond(to: connection, status: 200, type: "application/json", body: json)
    }

    private func serve(z: Int, x: Int, y: Int, to connection: NWConnection) async {
        do {
            let tile = try await terrainStore.fetchTile(z: z, x: x, y: y)
            let png = SlopeRaster.png(for: tile, z: z, x: x, y: y)
            respond(to: connection, status: 200, type: "image/png", body: png)
        } catch {
            respond(to: connection, status: 502, type: "text/plain", body: Data("\(error)".utf8))
        }
    }

    private func respond(to connection: NWConnection, status: Int, type: String, body: Data) {
        let reason = status == 200 ? "OK" : "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: max-age=3600\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Turns a decoded DEM tile into a slope-band PNG.
enum SlopeRaster {
    static func png(for tile: TerrainTile, z: Int, x: Int, y: Int) -> Data {
        // Meters per DEM pixel, from this tile's own mid-latitude.
        let midLatitude = (TileMath.bounds(of: TileCoordinate(z: z, x: x, y: y)).north
            + TileMath.bounds(of: TileCoordinate(z: z, x: x, y: y)).south) / 2
        let metersPerPixel = SlopeBands.metersPerPixel(
            zoom: z,
            midLatitude: midLatitude
        ) / Double(tile.width)

        let rgba = SlopeBands.slopeRgba(
            elevations: tile.elevations,
            width: tile.width,
            height: tile.height,
            ppx: metersPerPixel
        )
        return encodePNG(rgba, width: tile.width, height: tile.height)
    }

    private static func encodePNG(_ rgba: [UInt8], width: Int, height: Int) -> Data {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return Data() }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return Data() }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return output as Data
    }
}
