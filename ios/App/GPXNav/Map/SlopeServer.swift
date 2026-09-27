import Foundation
import Network
import RouteKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Loopback HTTP server that colorizes DEM tiles into slope rasters.
///
/// MapLibre Native has no equivalent of the web app's
/// `addProtocol('slope', …)` — `MLNMapViewDelegate`'s tile callback is
/// observational only, so it cannot supply data. This serves the same PNGs over
/// `http://127.0.0.1:<port>/slope/{z}/{x}/{y}.png` instead, which mirrors
/// `addProtocol` almost one-to-one and works inside offline packs too.
final class SlopeServer: @unchecked Sendable {
    private let listener: NWListener
    private let terrainStore: TerrainTileStore
    private let port: NWEndpoint.Port

    init(terrainStore: TerrainTileStore, port: UInt16) throws {
        self.terrainStore = terrainStore
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
