import Foundation
import Network
import RouteKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Loopback HTTP server for the three things MapLibre Native cannot be given
/// directly.
///
/// - `GET /tiles/{source}/{z}/{x}/{y}.{ext}` — basemap and elevation tiles.
///   Native has no equivalent of the web app's `addProtocol('slope', …)`:
///   `MLNMapViewDelegate`'s tile callback is observational only, so it cannot
///   supply data. The style is repointed here instead, which is what puts every
///   tile on disk — see `TileCache` and docs/ios-plan.md §9.
/// - `GET /slope/{z}/{x}/{y}.png` — slope rasters, from the same cached DEM.
/// - `GET /style.json?style=…&terrain=…` — MapTiler's style with the 3D terrain
///   block injected, because Native has no `setTerrain` equivalent either.
///
/// All three ride the one listener rather than opening a second port.
final class SlopeServer: @unchecked Sendable {
    private let styleBuilder: StyleBuilder
    private let tileCache: TileCache
    private let port: NWEndpoint.Port
    private let parameters: NWParameters
    /// Recreated on every bind attempt: a listener that has failed cannot be
    /// restarted, so retrying means a fresh one.
    private var listener: NWListener?
    private var bindAttempts = 0
    private let maxBindAttempts = 8

    init(
        styleBuilder: StyleBuilder,
        tileCache: TileCache,
        port: UInt16
    ) {
        self.styleBuilder = styleBuilder
        self.tileCache = tileCache
        self.port = NWEndpoint.Port(rawValue: port) ?? 8080
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.parameters = parameters
    }

    func start() {
        bind()
    }

    /// Create the listener and start it. `start()` is really "try again":
    /// `simctl` relaunches (and any OS relaunch) can start the new process
    /// while the old one is still tearing its own listener down, which holds
    /// the port for a fraction of a second — and the realistic failure here,
    /// EADDRINUSE, is otherwise permanent for the session: `NWListener` does
    /// not retry, MapLibre does not repeat a refused `style.json` ask, and
    /// without that ask this process never builds a style, so every tile 404s
    /// and the map stays blank until the next launch. See `onReady`.
    private func bind() {
        let url = "http://127.0.0.1:\(port.rawValue)"
        do {
            // `NWListener.start` reports bind failures only through the state
            // handler; without it a loopback that never comes up is
            // indistinguishable from broken tiles — flat background, route on
            // top, nothing else. `.ready` is the other half of that signal,
            // and the one the map waits on: binding is asynchronous, so
            // `start()` returning says nothing about whether the port accepts
            // yet.
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("SlopeServer bound to \(url)")
                    self?.bindAttempts = 0
                    self?.onReady?()
                case .failed(let error):
                    self?.bindFailed(error, url: url)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
                connection.start(queue: .global(qos: .utility))
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
            print("SlopeServer listening on \(url)")
        } catch {
            bindFailed(error, url: url)
        }
    }

    /// Release the spent listener and schedule another attempt.
    ///
    /// The first eight attempts are for ordinary teardown overlap — 0.25s
    /// backing off to 2s each, about twelve seconds in total, which is orders
    /// of magnitude longer than a port takes to clear. Past that the port is
    /// being held by something else entirely: a sibling simulator on the same
    /// host's network stack, or a relaunch that wedged rather than tore down.
    /// The original code gave up there, and giving up is permanent — nothing
    /// else retries, `onReady` never fires, `serverReady` never publishes, and
    /// the map sits white until the next launch. So the ladder ends in a slow
    /// steady retry instead: the views are already waiting on this bind, and a
    /// reattempt every few seconds costs nothing but a log line until the port
    /// comes back.
    private func bindFailed(_ error: Error, url: String) {
        listener = nil
        let delay: Double
        if bindAttempts < maxBindAttempts {
            bindAttempts += 1
            delay = min(0.25 * pow(2.0, Double(bindAttempts - 1)), 2.0)
            print("SlopeServer bind attempt \(bindAttempts) failed (\(error)); retrying in \(String(format: "%.2f", delay))s")
        } else {
            delay = 5.0
            print("SlopeServer still cannot bind (\(error)); retrying every \(Int(delay))s until the port frees")
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.bind()
        }
    }

    /// Called on the listener's queue once the port actually accepts.
    ///
    /// The gap between `start()` and `.ready` is real, and a `style.json`
    /// asked for inside it comes back refused — which MapLibre treats as
    /// final: it never re-asks, and its resource cache can paper over the
    /// failure with a copy from an earlier launch, so this session's
    /// `StyleBuilder` never runs, `upstreamTemplates` stays empty, and every
    /// tile answers 404 "no basemap" while the server looks healthy.
    /// `AppServices.serverReady` publishes this to the views, which hold the
    /// map back until it fires instead of guessing at a delay.
    var onReady: (() -> Void)?

    func stop() {
        listener?.cancel()
        listener = nil
        bindAttempts = 0
    }

    // MARK: - Request handling

    private func handle(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            if let key = Self.parseTileRequest(request) {
                Task { await self.serveTile(key, to: connection) }
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

    /// The request target, e.g. `/tiles/outdoor/12/656/1583.pbf`, or nil when
    /// this is not a GET.
    static func requestPath(_ request: String) -> String? {
        guard let line = request.split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    /// `GET /slope/{z}/{x}/{y}.png` → tile coordinates.
    static func parse(_ request: String) -> (z: Int, x: Int, y: Int)? {
        guard let path = requestPath(request) else { return nil }
        let pieces = path.split(separator: "/")
        guard pieces.count == 4, pieces[0] == "slope" else { return nil }
        guard pieces[3].hasSuffix(".png"),
              let z = Int(pieces[1]), let x = Int(pieces[2]),
              let y = Int(pieces[3].dropLast(4))
        else { return nil }
        return (z, x, y)
    }

    /// `GET /tiles/{source}/{z}/{x}/{y}.{ext}` → the cache key, whose source
    /// name and format extension are what keep the style's tile sets apart.
    static func parseTileRequest(_ request: String) -> TileCacheKey? {
        guard let path = requestPath(request) else { return nil }
        return TileCacheKey.parse(path: path)
    }

    /// Serve a tile from disk, fetching through to MapTiler on a miss.
    ///
    /// This is the seam that makes offline work at all: the style's basemap and
    /// elevation sources point here, so a cached tile never leaves the device,
    /// and looking at an area warms the cache as a side effect.
    private func serveTile(_ key: TileCacheKey, to connection: NWConnection) async {
        guard let template = await styleBuilder.upstreamTemplate(forSource: key.source) else {
            // Reached only when a style build genuinely finished without this
            // source — its own failure prints first. See `onReady` for the
            // refused-first-request version.
            print("SlopeServer: no upstream for \(key.source)")
            respond(to: connection, status: 404, type: "text/plain", body: Data("no basemap".utf8))
            return
        }
        guard let upstream = key.upstreamURL(template: template) else {
            respond(to: connection, status: 404, type: "text/plain", body: Data("bad upstream".utf8))
            return
        }
        do {
            let data = try await tileCache.data(for: key) { _ in
                try await Self.fetch(upstream)
            }
            respond(to: connection, status: 200, type: key.format.contentType, body: data)
        } catch {
            respond(to: connection, status: 502, type: "text/plain", body: Data("\(error)".utf8))
        }
    }

    /// A tile request with MapTiler's allowlisted identity applied.
    ///
    /// `MapNetworkIdentity.apply()` only reaches the session MapLibre created, so
    /// requests the app makes itself have to set the headers per request.
    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(MapNetworkIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(MapNetworkIdentity.versionHeader, forHTTPHeaderField: "X-GPXNav-Version")
        let (data, response) = try await BoundedFetch.data(request, session: .shared)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TileCache.CacheError.upstreamFailed(http.statusCode)
        }
        return data
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
        print("SlopeServer: style request \(style.rawValue) terrain=\(terrain)")

        guard let json = await styleBuilder.style(for: style, terrain: terrain) else {
            respond(to: connection, status: 502, type: "text/plain", body: Data("no style".utf8))
            return
        }
        respond(to: connection, status: 200, type: "application/json", body: json)
    }

    private func serve(z: Int, x: Int, y: Int, to connection: NWConnection) async {
        do {
            // Decode straight from the cached DEM tile rather than through
            // `terrainStore`, so slope shading works from the same bytes hillshade
            // and 3D terrain read — and therefore offline, once the corridor
            // download has fetched the DEM.
            let key = TileCacheKey(source: AppConfig.demSource, z: z, x: x, y: y, format: .webp)
            let data = try await demTileData(key)
            let tile = try TerrainTileStore.decodeTileData(data)
            let png = SlopeRaster.png(for: tile, z: z, x: x, y: y)
            respond(to: connection, status: 200, type: "image/png", body: png)
        } catch {
            respond(to: connection, status: 502, type: "text/plain", body: Data("\(error)".utf8))
        }
    }

    /// The DEM tile's bytes, from the cache, fetching from MapTiler on a miss.
    private func demTileData(_ key: TileCacheKey) async throws -> Data {
        if let cached = await tileCache.cached(key) { return cached }
        guard let template = await styleBuilder.upstreamTemplate(forSource: key.source) else {
            throw TerrainError.missingConfiguration
        }
        guard let upstream = key.upstreamURL(template: template) else {
            throw URLError(.badURL)
        }
        return try await tileCache.data(for: key) { _ in try await Self.fetch(upstream) }
    }

    private func respond(to connection: NWConnection, status: Int, type: String, body: Data) {
        // `no-store` is load-bearing, not tidy. MapLibre keeps its own copy of
        // every response in `.mapbox/cache.db`, and a style cached by an
        // earlier launch skips `StyleBuilder.style()` here — the only place
        // `upstreamTemplates` gets filled — so every tile in this session
        // answers 404 "no basemap" while the server itself looks fine. Tiles
        // persist through `TileCache` instead, by explicit key, so this layer
        // never needs to store anything.
        let reason = status == 200 ? "OK" : "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
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
