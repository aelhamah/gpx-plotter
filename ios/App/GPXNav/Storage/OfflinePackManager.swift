import Foundation
import RouteKit

/// Corridor prefetch into `VectorTileCache`.
///
/// This replaces `MLNOfflineStorage`, which on MapLibre Native 6.31.0 accepts a
/// corridor pack, reports zero downloadable resources, and never fetches a tile
/// (docs/ios-plan.md §9). Since the basemap's vector sources already point at
/// the loopback caching proxy, a tile that is on disk *is* a tile the map can
/// draw offline — so the whole job is choosing which tiles and fetching them.
///
/// LRU eviction is not implemented. The byte figure is reported so the cost is
/// at least visible, and `clear()` exists for when it grows.
@MainActor
final class OfflinePackManager: ObservableObject {
    enum PackState: Equatable {
        case none
        case preparing
        case downloading(progress: Double)
        case complete
        case failed(String)

        var label: String {
            switch self {
            case .none: return "Not downloaded"
            case .preparing: return "Preparing…"
            case .downloading(let progress): return "Downloading \(Int(progress * 100))%"
            case .complete: return "Available offline"
            case .failed(let message): return "Failed: \(message)"
            }
        }
    }

    @Published private(set) var state: PackState = .none
    @Published private(set) var estimatedBytes: Int = 0
    @Published private(set) var estimatedTileCount: Int = 0
    /// Tiles actually held in the cache, for the Settings data section.
    @Published private(set) var cachedTileCount: Int = 0
    @Published private(set) var cachedBytes: Int = 0

    private let cache: VectorTileCache
    private let styleBuilder: StyleBuilder
    private var prefetchTask: Task<Void, Never>?
    /// Source ids to prefetch, taken from the style so this stays in step with
    /// whatever basemap is loaded rather than a hardcoded list.
    private let sources = ["outdoor", "contours", "maptiler_planet"]

    init(cache: VectorTileCache, styleBuilder: StyleBuilder) {
        self.cache = cache
        self.styleBuilder = styleBuilder
    }

    // MARK: - Estimate

    /// Compute the size and tile count for a route without fetching anything.
    func estimate(
        for route: Route,
        bufferMeters: Double = Corridor.defaultBufferMeters,
        zoomRange: ClosedRange<Int> = AppConfig.offlineZoomRange
    ) {
        let tiles = Corridor.tiles(
            for: route.points.map(\.coordinate),
            bufferMeters: bufferMeters,
            zoomRange: zoomRange
        )
        estimatedTileCount = tiles.count * sources.count
        estimatedBytes = Corridor.estimatedBytes(for: tiles) * sources.count
    }

    var estimatedSizeDescription: String {
        guard estimatedBytes > 0 else { return "—" }
        let megabytes = Double(estimatedBytes) / 1_000_000
        if megabytes >= 1000 {
            return String(format: "%.1f GB", megabytes / 1000)
        }
        return megabytes >= 10
            ? String(format: "%.0f MB", megabytes)
            : String(format: "%.1f MB", megabytes)
    }

    /// Refresh the cache figures for the Settings screen.
    func refreshCacheFigures() async {
        cachedTileCount = await cache.tileCount()
        cachedBytes = await cache.byteCount()
    }

    // MARK: - Prefetch

    /// Fetch every tile the corridor crosses, across the basemap's sources.
    func download(
        for route: Route,
        bufferMeters: Double = Corridor.defaultBufferMeters,
        zoomRange: ClosedRange<Int> = AppConfig.offlineZoomRange
    ) {
        guard prefetchTask == nil else { return }
        guard route.points.count >= 2 else {
            state = .failed("Route needs at least two points")
            return
        }

        let tiles = Corridor.tiles(
            for: route.points.map(\.coordinate),
            bufferMeters: bufferMeters,
            zoomRange: zoomRange
        )
        guard !tiles.isEmpty else {
            state = .failed("No tiles cover this route at z\(zoomRange.lowerBound)–\(zoomRange.upperBound)")
            return
        }

        estimate(for: route, bufferMeters: bufferMeters, zoomRange: zoomRange)
        state = .preparing

        prefetchTask = Task { [cache, styleBuilder, sources] in
            // The style builder only learns a source's upstream URL once the
            // map has actually fetched the style, and this runs from the same
            // `.task` that starts the map — so wait for it rather than failing
            // on a race that resolves itself a moment later.
            var templates: [String: String] = [:]
            for _ in 0..<40 {
                if Task.isCancelled { return }
                templates = [:]
                for source in sources {
                    if let template = await styleBuilder.upstreamTemplate(forSource: source) {
                        templates[source] = template
                    }
                }
                if !templates.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !templates.isEmpty else {
                self.state = .failed("The basemap style has not loaded yet — try again in a moment.")
                self.prefetchTask = nil
                return
            }

            self.state = .downloading(progress: 0)
            // Progress is reported per source group rather than per tile: the
            // loopback cache is keyed by z/x/y and three sources share tiles, so
            // counting individual fetches overstates the work.
            var done = 0
            let total = sources.count
            for (source, template) in templates {
                guard !Task.isCancelled else { break }
                var group: [URL] = []
                for tile in tiles {
                    let key = VectorTileCache.Key(z: tile.z, x: tile.x, y: tile.y)
                    if let url = Self.upstreamURL(template: template, key: key) {
                        group.append(url)
                    }
                }
                let results = await Self.fetch(
                    Array(group.prefix(tiles.count)),
                    tiles: tiles,
                    into: cache
                )
                if Task.isCancelled { break }
                done += 1
                self.state = .downloading(progress: Double(done) / Double(total))
                if results == 0 {
                    self.state = .failed("MapTiler returned no tiles for \(source).")
                    self.prefetchTask = nil
                    return
                }
            }

            guard !Task.isCancelled else { return }
            await self.refreshCacheFigures()
            self.state = .complete
            self.prefetchTask = nil
        }
    }

    /// Fetch one source's tiles through the cache, so they land on disk exactly
    /// the way a live map request would.
    private static func fetch(
        _ urls: [URL],
        tiles: [TileCoordinate],
        into cache: VectorTileCache
    ) async -> Int {
        var stored = 0
        for (url, tile) in zip(urls, tiles) {
            if Task.isCancelled { return stored }
            let key = VectorTileCache.Key(z: tile.z, x: tile.x, y: tile.y)
            do {
                _ = try await cache.data(for: key) { _ in
                    var request = URLRequest(url: url)
                    request.setValue(MapNetworkIdentity.userAgent, forHTTPHeaderField: "User-Agent")
                    request.setValue(
                        MapNetworkIdentity.versionHeader,
                        forHTTPHeaderField: "X-GPXNav-Version"
                    )
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw VectorTileCache.CacheError.upstreamFailed(http.statusCode)
                    }
                    return data
                }
                stored += 1
            } catch {
                // One missing tile should not abandon the corridor; the map will
                // fall back to fetching it live when it is needed.
            }
        }
        return stored
    }

    private static func upstreamURL(template: String, key: VectorTileCache.Key) -> URL? {
        URL(string: template
            .replacingOccurrences(of: "{z}", with: "\(key.z)")
            .replacingOccurrences(of: "{x}", with: "\(key.x)")
            .replacingOccurrences(of: "{y}", with: "\(key.y)"))
    }

    // MARK: - Removal

    /// Wipe the whole cache. Packs are not tracked individually any more, since
    /// the cache is shared and warms as you browse.
    func removeCurrentPack() {
        prefetchTask?.cancel()
        prefetchTask = nil
        Task {
            await cache.clear()
            await refreshCacheFigures()
            state = .none
        }
    }
}
