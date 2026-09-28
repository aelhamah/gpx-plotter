import Foundation
import RouteKit

/// Corridor prefetch into `TileCache`.
///
/// This replaces `MLNOfflineStorage`, which on MapLibre Native 6.31.0 accepts a
/// corridor pack, reports zero downloadable resources, and never fetches a tile
/// (docs/ios-plan.md §9). Since the basemap's sources already point at the
/// loopback caching proxy, a tile that is on disk *is* a tile the map can draw
/// offline — so the whole job is choosing which tiles and fetching them.
///
/// Which tiles means *which sources*, not just which coordinates: `outdoor` and
/// `contours` are different payloads at the same `z/x/y`, and elevation is a
/// third. The list is read from the loaded style, so switching basemaps changes
/// what a download covers instead of quietly leaving the satellite imagery out.
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
    /// Tiles the last download could not fetch, so the coverage can be reported
    /// honestly instead of claiming a clean success over holes.
    @Published private(set) var skippedTileCount: Int = 0
    /// Tiles actually held in the cache, for the Settings data section and the
    /// offline row.
    @Published private(set) var cachedTileCount: Int = 0
    @Published private(set) var cachedBytes: Int = 0

    private let cache: TileCache
    private let styleBuilder: StyleBuilder
    private var prefetchTask: Task<Void, Never>?

    /// How many tile requests may be in flight. Sequential is the safest thing
    /// to do to a single API key, and a corridor is a few hundred tiles, so a
    /// handful at a time rather than a flood.
    private static let maxConcurrentFetches = 4

    init(cache: TileCache, styleBuilder: StyleBuilder) {
        self.cache = cache
        self.styleBuilder = styleBuilder
    }

    // MARK: - Tile list

    /// Every tile the corridor needs, for every source the style depends on.
    ///
    /// Basemap and elevation both come across `zoomRange`, because MapLibre asks
    /// for a DEM tile at the camera's zoom rather than at one fixed level — a
    /// corridor that covered the basemap at z12–z14 but only elevation at z14
    /// would lose its hillshade and 3D terrain at every other zoom. The DEM tops
    /// out at `Corridor.demZoomRange.upperBound`, which is what the intersection
    /// clamps.
    private func tileKeys(
        for route: Route,
        sources: [BasemapSource],
        bufferMeters: Double,
        zoomRange: ClosedRange<Int>
    ) -> [TileCacheKey] {
        let coordinates = route.points.map(\.coordinate)
        let elevationRange = zoomRange.lowerBound...min(zoomRange.upperBound, Corridor.demZoomRange.upperBound)
        var keys: [TileCacheKey] = []

        for source in sources {
            let range = source.isElevation ? elevationRange : zoomRange
            keys.append(contentsOf: Corridor.tiles(
                for: coordinates,
                bufferMeters: bufferMeters,
                zoomRange: range
            ).map { TileCacheKey(tile: $0, source: source.name, format: source.format) })
        }
        return keys
    }

    // MARK: - Estimate

    /// Compute the size and tile count for a route without fetching anything.
    func estimate(
        for route: Route,
        bufferMeters: Double = Corridor.defaultBufferMeters,
        zoomRange: ClosedRange<Int> = AppConfig.offlineZoomRange
    ) async {
        let sources = await styleBuilder.basemapSources()
        guard !sources.isEmpty else { return }
        applyEstimate(for: tileKeys(
            for: route,
            sources: sources,
            bufferMeters: bufferMeters,
            zoomRange: zoomRange
        ))
    }

    /// The estimate, from a tile list that has already been worked out.
    ///
    /// Per source, not a flat per-tile figure: the tile sets a style needs range
    /// from a few KB to 200 KB at the same zoom, and the style the user is
    /// looking at decides which of those is being downloaded.
    private func applyEstimate(for keys: [TileCacheKey]) {
        estimatedTileCount = keys.count
        estimatedBytes = keys.reduce(0) {
            $0 + TileSourceSize.approximateBytes(source: $1.source, format: $1.format, zoom: $1.z)
        }
    }

    var estimatedSizeDescription: String {
        guard estimatedBytes > 0 else { return "—" }
        return Self.describe(bytes: estimatedBytes)
    }

    var cachedSizeDescription: String {
        Self.describe(bytes: cachedBytes)
    }

    private static func describe(bytes: Int) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 1000 {
            return String(format: "%.1f GB", megabytes / 1000)
        }
        return megabytes >= 10
            ? String(format: "%.0f MB", megabytes)
            : String(format: "%.1f MB", megabytes)
    }

    /// Refresh the cache figures for the Settings screen and the offline row.
    func refreshCacheFigures() async {
        cachedTileCount = await cache.tileCount()
        cachedBytes = await cache.byteCount()
    }

    // MARK: - Prefetch

    /// Fetch every tile the corridor crosses, for every source the style needs.
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

        state = .preparing

        prefetchTask = Task { [styleBuilder] in
            // Cleared on every exit, including a cancellation, so a cancelled
            // download cannot leave the row spinning forever.
            defer { self.prefetchTask = nil }

            // The style builder only learns a source's upstream URL once the map
            // has actually fetched the style, and this runs from the same
            // `.task` that starts the map — so wait for it rather than failing on
            // a race that resolves itself a moment later.
            var sources: [BasemapSource] = []
            for _ in 0..<40 {
                if Task.isCancelled { return }
                sources = await styleBuilder.basemapSources()
                if !sources.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !sources.isEmpty else {
                self.state = .failed("The basemap style has not loaded yet — try again in a moment.")
                return
            }

            let keys = self.tileKeys(
                for: route,
                sources: sources,
                bufferMeters: bufferMeters,
                zoomRange: zoomRange
            )
            guard !keys.isEmpty else {
                self.state = .failed("No tiles cover this route at z\(zoomRange.lowerBound)–\(zoomRange.upperBound)")
                return
            }
            self.applyEstimate(for: keys)

            // Resolve every upstream before fetching, so the requests themselves
            // are pure cache writes and cannot fail on a missing template.
            var pending: [(key: TileCacheKey, url: URL)] = []
            for key in keys {
                guard let template = await styleBuilder.upstreamTemplate(forSource: key.source),
                      let url = key.upstreamURL(template: template)
                else { continue }
                pending.append((key, url))
            }
            guard !pending.isEmpty else {
                self.state = .failed("The basemap style has not resolved its tile sources yet.")
                return
            }

            self.state = .downloading(progress: 0)
            let (stored, skipped) = await self.prefetch(pending)
            if Task.isCancelled { return }

            await self.refreshCacheFigures()
            self.skippedTileCount = skipped
            self.state = stored == 0
                ? .failed("MapTiler returned no tiles. Check that the key allows native requests.")
                : .complete
        }
    }

    /// Fetch a list of tiles, a few at a time, reporting after each one.
    ///
    /// The cache deduplicates what is already on disk, so a corridor overlapping
    /// somewhere already looked at costs nothing to ask for.
    private func prefetch(
        _ pending: [(key: TileCacheKey, url: URL)]
    ) async -> (stored: Int, skipped: Int) {
        var stored = 0
        var skipped = 0
        var completed = 0

        for chunk in pending.chunked(into: Self.maxConcurrentFetches) {
            let results = await withTaskGroup(of: Bool.self) { group in
                for item in chunk {
                    group.addTask { [cache] in
                        do {
                            _ = try await cache.data(for: item.key) { _ in
                                try await SlopeServer.fetch(item.url)
                            }
                            return true
                        } catch {
                            // One missing tile should not abandon the corridor;
                            // the map falls back to fetching it live.
                            return false
                        }
                    }
                }
                var outcomes: [Bool] = []
                for await ok in group {
                    outcomes.append(ok)
                }
                return outcomes
            }

            for ok in results {
                completed += 1
                if ok { stored += 1 } else { skipped += 1 }
            }
            state = .downloading(progress: Double(completed) / Double(pending.count))
        }
        return (stored, skipped)
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

extension Array {
    /// Split into fixed-size chunks, the last one shorter if needed.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
