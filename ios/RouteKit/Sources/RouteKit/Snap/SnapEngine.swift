import Foundation

/// Max distance (m) a drawn route point may be from a trail to snap onto it.
///
/// This doubles as the test for whether the route should then run *along* that
/// trail: the point has already been moved onto the trail by the snap, so
/// following it moves the point no further. Gating following on a tighter
/// radius than the snap used to reject legs whose points had snapped
/// successfully — on a recorded 12.5 km hike that silently cost a third of all
/// drawn segments. Verbatim from the web app's `snap.ts`.
public let TRAIL_SNAP_METERS = 40.0

/// Max distance (m) a placed waypoint may be from a peak to snap onto it.
public let PEAK_SNAP_METERS = 250.0

/// Snapping is on unless the user turns it off, including for saved
/// workspaces.
public let SNAP_ENABLED_BY_DEFAULT = true

/// What the draw bar says while a route is being drawn. The snapping clause is
/// dropped rather than negated when snapping is off, because the user has not
/// opted out of a feature that failed — they switched it off on purpose. Port
/// of `drawStatusText` in `web/src/snap.ts`.
public func drawStatusText(pointCount: Int, snappingEnabled: Bool) -> String {
    if pointCount >= 2 { return "Tap Finish to end the route" }
    return snappingEnabled
        ? "Tap the map to add points — snaps to trails"
        : "Tap the map to add points"
}

/// The hint shown while placing a single waypoint, which snaps to peaks. Port
/// of `waypointHintText` in `web/src/snap.ts`.
public func waypointHintText(snappingEnabled: Bool) -> String {
    snappingEnabled
        ? "Tap to place a waypoint · snaps to peaks"
        : "Tap to place a waypoint"
}

/// One peak as a snap candidate carries it.
public struct PeakInfo: Equatable, Sendable {
    public var name: String?
    public var elevation: Double?
    public var center: Coordinate

    public init(name: String? = nil, elevation: Double? = nil, center: Coordinate) {
        self.name = name
        self.elevation = elevation
        self.center = center
    }
}

/// Fetches snap candidates from MapTiler's vector tilesets:
///  - `outdoor` → the "trail" layer (marked hiking/biking routes), and
///  - planet (v3) → the "transportation" layer, filtered to path-like classes,
///    because the `trail` layer only carries trails that belong to a route
///    relation (many ordinary paths are missing there), and
///  - planet (v3) → the "mountain_peak" layer for snapping waypoints onto
///    peaks.
///
/// Port of the web app's `web/src/snapSources.ts`, with one addition the web
/// does not need: tiles already on disk — warmed by browsing, or downloaded by
/// a corridor prefetch — are read before the network is touched. That is what
/// makes snapping work in airplane mode over an area you have already looked
/// at, which on a phone is the case that matters: the map is offline first and
/// the network is the fallback, not the other way round.
///
/// These are the same tilesets the map style already references, read at the
/// zoom the map is showing and clamped to each tileset's own maximum zoom (see
/// `SnapTiles`). A radius query spans every tile the radius can reach into, so
/// a snap near a tile boundary does not lose candidates. Decoded tiles are
/// cached per source/z/x/y; failed reads are dropped from the cache so one bad
/// response does not disable snapping for that tile for the rest of the
/// session.
public actor SnapEngine {
    /// Cap on decoded tiles held in memory. At snap zoom a tile is a few KB of
    /// geometry; 256 tiles covers a long drawing session without pressure.
    static let cacheCap = 256

    /// `transportation` classes that count as a walkable/rideable trail.
    static let trailClasses: Set<String> = [
        "path", "footway", "steps", "track", "cycleway", "bridleway",
        "pedestrian", "corridor",
    ]

    struct DecodedTile {
        var layers: [MVT.Layer]
        var z: Int
        var x: Int
        var y: Int
    }

    private var tileCache: [String: DecodedTile] = [:]
    private var tileCacheOrder: [String] = []
    private let httpClient: HTTPClient
    private let config: MapTilerConfig?
    private let diskCache: TileCache?

    /// - Parameters:
    ///   - httpClient: injectable for tests, as everywhere else in RouteKit.
    ///   - config: the proxy base URL; nil means "no network", in which case
    ///     only the disk cache can answer — the airplane-mode case.
    ///   - diskCache: the shared tile cache the map reads through. Snap reads
    ///     it first and stores network fetches back into it, so a snap that had
    ///     to go online still warms the area for next time.
    public init(
        httpClient: HTTPClient = DefaultHTTPClient(),
        config: MapTilerConfig? = nil,
        diskCache: TileCache? = nil
    ) {
        self.httpClient = httpClient
        self.config = config
        self.diskCache = diskCache
    }

    private func urlTemplate(for tileset: SnapTiles.TilesetId) -> String? {
        switch tileset {
        case .outdoor: return config?.outdoorTileURL
        case .planet: return config?.planetTileURL
        }
    }

    /// Decode one tile from the network, or read it from the shared disk cache
    /// first. A failed read is *not* left in the in-memory cache: caching the
    /// rejection is what used to make a single 429 or 400 silently disable
    /// snapping over an area until the page was reloaded.
    private func readTile(_ tileset: SnapTiles.TilesetId, z: Int, tile: SnapTiles.TileAddress) async throws -> DecodedTile {
        let key = "\(tileset.rawValue)/\(z)/\(tile.x)/\(tile.y)"
        if let cached = tileCache[key] { return cached }

        let data = try await fetchBytes(tileset, z: z, tile: tile)
        let layers = try MVT.decodeTile(data)
        let decoded = DecodedTile(layers: layers, z: z, x: tile.x, y: tile.y)

        if tileCacheOrder.count >= Self.cacheCap, let oldest = tileCacheOrder.first {
            tileCache.removeValue(forKey: oldest)
            tileCacheOrder.removeFirst()
        }
        tileCache[key] = decoded
        tileCacheOrder.append(key)
        return decoded
    }

    private func fetchBytes(_ tileset: SnapTiles.TilesetId, z: Int, tile: SnapTiles.TileAddress) async throws -> Data {
        // Disk first: a tile the map has already drawn (or a corridor
        // downloaded) answers without the network, which is the whole offline
        // story. The style caches the planet tileset under `maptiler_planet`,
        // so that alias is read too.
        if let diskCache {
            let names = [tileset.cacheSourceName, tileset == .planet ? "v3" : tileset.rawValue]
            for name in names {
                let key = TileCacheKey(source: name, z: z, x: tile.x, y: tile.y, format: .pbf)
                if let hit = await diskCache.cached(key) { return hit }
            }
        }

        guard let template = urlTemplate(for: tileset),
              let url = config?.tileURL(template, z: z, x: tile.x, y: tile.y)
        else { throw SnapEngineError.noConfiguration }

        let (data, response) = try await httpClient.data(from: url.absoluteString)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SnapEngineError.tileFailed("\(tileset.rawValue)/\(z)/\(tile.x)/\(tile.y)", http.statusCode)
        }
        // Store back into the shared cache under the style's source name, so a
        // snap that went online is offline next time.
        if let diskCache {
            await diskCache.store(
                data,
                for: TileCacheKey(source: tileset.cacheSourceName, z: z, x: tile.x, y: tile.y, format: .pbf)
            )
        }
        return data
    }

    public enum SnapEngineError: Error, LocalizedError, Equatable {
        case noConfiguration
        case tileFailed(String, Int)

        public var errorDescription: String? {
            switch self {
            case .noConfiguration: return "No MapTiler configuration; snap tiles cannot be fetched."
            case .tileFailed(let key, let status): return "Snap tile \(key) failed with HTTP \(status)."
            }
        }
    }

    struct TileRead {
        var decoded: [DecodedTile]
        var failures: [String]
        var attempted: Int
    }

    /// Read every tile of one tileset whose area can hold a candidate within
    /// `radiusMeters`, keeping the ones that succeeded so a single unreachable
    /// tile costs its own candidates rather than the whole snap.
    ///
    /// The tile ring is worked out per tileset, at the zoom that tileset is
    /// actually being asked for: the outdoor tileset caps out one zoom short of
    /// the planet one, and its tile indices are on a different grid at that
    /// zoom.
    private func readTiles(
        _ tileset: SnapTiles.TilesetId,
        zoom: Int,
        lng: Double,
        lat: Double,
        radiusMeters: Double
    ) async -> TileRead {
        let z = SnapTiles.zoom(forTileset: tileset, at: zoom)
        let tiles = SnapTiles.tilesNear(lng: lng, lat: lat, zoom: z, radiusMeters: radiusMeters)
        if tiles.isEmpty { return TileRead(decoded: [], failures: [], attempted: 0) }

        var decoded: [DecodedTile] = []
        var failures: [String] = []
        await withTaskGroup(of: Result<DecodedTile, Error>.self) { group in
            for tile in tiles {
                group.addTask { [self] in
                    do { return .success(try await readTile(tileset, z: z, tile: tile)) }
                    catch { return .failure(error) }
                }
            }
            for await result in group {
                switch result {
                case .success(let tile): decoded.append(tile)
                case .failure(let error): failures.append(String(describing: error))
                }
            }
        }
        return TileRead(decoded: decoded, failures: failures, attempted: tiles.count)
    }

    private func tilePointLine(_ part: [MVT.Pixel], _ tile: DecodedTile, extent: Int) -> [Coordinate] {
        part.map { MVT.tilePointToCoordinate(z: tile.z, x: tile.x, y: tile.y, extent: extent, px: Double($0.x), py: Double($0.y)) }
    }

    private func lines(
        from tile: DecodedTile,
        layerName: String,
        keep: (([String: MVT.Value]) -> Bool)? = nil
    ) -> [[Coordinate]] {
        guard let layer = MVT.layer(named: layerName, in: tile.layers) else { return [] }
        var out: [[Coordinate]] = []
        for feature in layer.features {
            if feature.type != 2 { continue }
            if let keep, !keep(feature.props) { continue }
            for part in feature.parts where !part.isEmpty {
                out.append(tilePointLine(part, tile, extent: layer.extent))
            }
        }
        return out
    }

    /// The outcome of one trail query: the candidate polylines, plus enough
    /// bookkeeping for the caller to tell "no trail here" from "no tiles came
    /// back". Snapping fails silently by design — an outage and a genuine miss
    /// look identical to the person tapping — but the counts travel back so a
    /// caller *can* speak up when every tile of both sources failed, which is
    /// the web app's service-banner condition.
    public struct TrailQuery: Equatable, Sendable {
        public var lines: [[Coordinate]]
        public var attempted: Int
        public var failures: [String]

        /// Every tile read failed — the only case worth reporting.
        public var totalFailure: Bool { SnapEngine.totalFailure(attempted: attempted, failures: failures.count) }
    }

    /// Trail polylines within `radiusMeters` of a point, combining the marked
    /// `trail` layer with path-like `transportation` lines. `zoom` is the map's
    /// current zoom; it is clamped to what the tilesets serve. Returns no lines
    /// when every source fails.
    public func trailsNearPoint(
        lng: Double,
        lat: Double,
        zoom: Int = SnapTiles.snapMinZoom,
        radiusMeters: Double = TRAIL_SNAP_METERS
    ) async -> TrailQuery {
        async let marked = readTiles(.outdoor, zoom: zoom, lng: lng, lat: lat, radiusMeters: radiusMeters)
        async let paths = readTiles(.planet, zoom: zoom, lng: lng, lat: lat, radiusMeters: radiusMeters)
        let (markedRead, pathsRead) = await (marked, paths)

        let markedLines = markedRead.decoded.flatMap { lines(from: $0, layerName: "trail") }
        let pathLines = pathsRead.decoded.flatMap { tile in
            lines(from: tile, layerName: "transportation") { props in
                props["class"]?.stringValue.map { Self.trailClasses.contains($0) } ?? false
            }
        }

        return TrailQuery(
            lines: markedLines + pathLines,
            attempted: markedRead.attempted + pathsRead.attempted,
            failures: markedRead.failures + pathsRead.failures
        )
    }

    /// Peaks within `radiusMeters` of a point. The `attempted`/`failures`
    /// counts carry the same meaning as `TrailQuery`'s.
    public func peaksNearPoint(
        lng: Double,
        lat: Double,
        zoom: Int = SnapTiles.snapMinZoom,
        radiusMeters: Double = PEAK_SNAP_METERS
    ) async -> (peaks: [PeakInfo], attempted: Int, failures: [String]) {
        let read = await readTiles(.planet, zoom: zoom, lng: lng, lat: lat, radiusMeters: radiusMeters)
        var peaks: [PeakInfo] = []
        for tile in read.decoded {
            guard let layer = MVT.layer(named: "mountain_peak", in: tile.layers) else { continue }
            for feature in layer.features {
                if feature.type != 1 { continue }
                for part in feature.parts {
                    let px = part.first?.x ?? 0
                    let py = part.first?.y ?? 0
                    let center = MVT.tilePointToCoordinate(
                        z: tile.z, x: tile.x, y: tile.y, extent: layer.extent,
                        px: Double(px), py: Double(py)
                    )
                    let name = feature.props["name"]?.stringValue
                    let elevation = feature.props["ele"]?.numberValue
                    peaks.append(PeakInfo(name: name, elevation: elevation, center: center))
                }
            }
        }
        return (peaks, read.attempted, read.failures)
    }

    /// Whether every tile read failed — the only case the web app's banner
    /// speaks up for, since a partial read is a normal, recoverable edge and
    /// the basemap draws from these same tilesets.
    public static func totalFailure(attempted: Int, failures: Int) -> Bool {
        attempted > 0 && failures == attempted
    }
}
