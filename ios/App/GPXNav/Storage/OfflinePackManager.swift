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
/// What the user deliberately downloaded is recorded in an `OfflinePackManifest`,
/// because the cache itself cannot answer that: it warms as the map is panned, so
/// most of what is on disk belongs to no route at all. The manifest says which
/// tiles were asked for; the storage screen attributes the rest as browsing, and
/// eviction is now possible but never automatic — silently deleting a download the
/// hiker made last week is not a decision to take for them.
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
    /// What was deliberately downloaded, newest first. The storage screen's list.
    @Published private(set) var packs: [OfflinePack] = []
    /// Tiles on disk that no pack accounts for: the map was panned somewhere, or a
    /// pack was deleted and the cache kept whatever it had picked up around it.
    ///
    /// Reported rather than hidden, because "4.4 MB of offline maps" next to a
    /// list that adds up to 4.1 MB is the kind of discrepancy that makes a storage
    /// screen untrustworthy.
    @Published private(set) var unattributedTileCount: Int = 0
    @Published private(set) var unattributedBytes: Int = 0
    /// True while a delete or eviction is running, so the buttons can say so rather
    /// than appearing to do nothing.
    @Published private(set) var isPruning = false
    /// True once an estimate has been asked for while the style's sources were
    /// still unresolved. Drives the "still working" wording in the offline row.
    @Published private var isAwaitingSources = false

    private let cache: TileCache
    private let styleBuilder: StyleBuilder
    /// The library, so a pack's tiles can be rebuilt from its record when they
    /// have to be deleted.
    ///
    /// Weak, and set by the app rather than in `init`: this manager is created by
    /// `AppServices` and the workspace by the app, and a snapshot of the routes
    /// taken at launch would not see an import or a deletion. The two live in the
    /// same process for the app's lifetime, so this is a convenience rather than
    /// a lifetime hazard — but weak says so.
    weak var workspace: WorkspaceStore?
    private let manifestStore: OfflinePackManifestStore
    private var manifest: OfflinePackManifest
    private var prefetchTask: Task<Void, Never>?

    /// How many tile requests may be in flight. Sequential is the safest thing
    /// to do to a single API key, and a corridor is a few hundred tiles, so a
    /// handful at a time rather than a flood.
    private static let maxConcurrentFetches = 4

    init(
        cache: TileCache,
        styleBuilder: StyleBuilder,
        manifestStore: OfflinePackManifestStore = OfflinePackManifestStore()
    ) {
        self.cache = cache
        self.styleBuilder = styleBuilder
        self.manifestStore = manifestStore
        manifest = manifestStore.load()
        packs = manifest.packs
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
        sources: [TileSourceRef],
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
        guard !sources.isEmpty else {
            // No sources means the style has not finished resolving, not that
            // there is nothing to download. Leaving the estimate at zero and
            // saying nothing is what left a permanently disabled Download button
            // with "No offline estimate yet" under it.
            isAwaitingSources = true
            return
        }
        isAwaitingSources = false
        applyEstimate(for: tileKeys(
            for: route,
            sources: sources.map(TileSourceRef.init),
            bufferMeters: bufferMeters,
            zoomRange: zoomRange
        ))
    }

    /// What to say when there is still no estimate.
    ///
    /// "Still working" and "never going to work" are different problems, and
    /// showing the same dead row for both is why this read as a broken control.
    var pendingEstimateNote: String {
        if isAwaitingSources {
            return "Working out which tiles this route needs…"
        }
        if AppConfig.styleSource == .mapLibreDemo {
            return "Offline download needs a MapTiler basemap. The demo tileset stops at z6."
        }
        return "The basemap's tile sources could not be read, so there is nothing to estimate."
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

    /// Bytes as "4.4 MB". Shared with the storage screen so the two cannot
    /// disagree about the same figure.
    static func describe(bytes: Int) -> String {
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
                sources: sources.map(TileSourceRef.init),
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

            self.skippedTileCount = skipped
            if stored == 0 {
                self.state = .failed("MapTiler returned no tiles. Check that the key allows native requests.")
            } else {
                // Recorded only on success, and from what is actually on disk
                // rather than from the estimate: a partial corridor is still a
                // corridor, and the storage screen must not claim coverage the
                // download did not get.
                let measured = await cache.measure(keys)
                self.record(OfflinePack(
                    id: String(route.id),
                    name: route.name,
                    tileCount: measured.tiles,
                    byteCount: measured.bytes,
                    downloadedAt: Date(),
                    bufferMeters: bufferMeters,
                    zoomRange: zoomRange,
                    sources: sources.map { OfflinePackSource(name: $0.name, format: $0.format) }
                ))
                self.state = .complete
            }
            await self.refreshCacheFigures()
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

    // MARK: - Storage

    /// Work out which tiles each pack is responsible for, and what is left over.
    ///
    /// Measured rather than read back from the records, because tiles are shared
    /// between overlapping corridors and warm up from browsing: a pack's recorded
    /// byte count is what it asked for, and the honest current figure is what its
    /// keys are worth now.
    func refreshAttribution() async {
        var attributedTiles = 0
        var attributedBytes = 0

        for pack in manifest.packs {
            let keys = await keys(for: pack)
            let measured = await cache.measure(keys)
            attributedTiles += measured.tiles
            attributedBytes += measured.bytes
        }

        let allTiles = await cache.tileCount()
        let allBytes = await cache.byteCount()
        unattributedTileCount = max(0, allTiles - attributedTiles)
        unattributedBytes = max(0, allBytes - attributedBytes)
    }

    /// Delete one corridor's tiles and forget it.
    ///
    /// The keys come back from the route, which is why the manifest keeps a route
    /// id: a pack whose route has since been deleted from the library still lists
    /// its tiles, and falls back to wiping the cache rather than leaving a record
    /// it cannot honour.
    func deletePack(_ pack: OfflinePack, route: Route?) {
        isPruning = true
        Task {
            let keysToDelete: [TileCacheKey]
            if let route {
                keysToDelete = await keys(for: pack, route: route)
            } else {
                // The route behind this pack is gone, so its tiles cannot be listed.
                // Wiping the cache is blunt, but the alternative is a record that
                // says "downloaded" with nothing behind it.
                await cache.clear()
                keysToDelete = []
            }
            if !keysToDelete.isEmpty { await cache.remove(keysToDelete) }
            manifest.remove(id: pack.id)
            persist()
            state = .none
            await refreshCacheFigures()
            await refreshAttribution()
            isPruning = false
        }
    }

    /// Drop the oldest corridors until the recorded total is within `limit`.
    ///
    /// Offered rather than automatic. A budget that silently deletes last week's
    /// download is worse than a storage screen that says the cache is large.
    func freeSpace(to limit: Int = AppConfig.offlineByteBudget) {
        isPruning = true
        Task {
            for pack in manifest.evict(over: limit) {
                if let route = workspace?.routes.first(where: { $0.id == Int(pack.id) }) {
                    await cache.remove(await keys(for: pack, route: route))
                } else {
                    // The route behind this pack is gone, so its tiles cannot be
                    // listed. Dropping the whole cache is blunt but honest, and it
                    // is the one case where the user has already lost the route.
                    await cache.clear()
                }
            }
            persist()
            await refreshCacheFigures()
            await refreshAttribution()
            isPruning = false
        }
    }

    /// The record for a route, if its corridor has been downloaded.
    ///
    /// This is what makes the offline bar honest across launches: `state` only
    /// describes the current session, so without it a route downloaded yesterday
    /// reads as "Not downloaded" today, next to a Download button that would
    /// fetch what is already on disk.
    func pack(for route: Route) -> OfflinePack? {
        manifest.pack(id: String(route.id))
    }

    /// Whether a free-space run would have anything to do.
    var canFreeSpace: Bool { manifest.totalBytes > AppConfig.offlineByteBudget }

    /// Wipe every tile and every record.
    func removeAllTiles() {
        isPruning = true
        Task {
            prefetchTask?.cancel()
            prefetchTask = nil
            await cache.clear()
            manifest = OfflinePackManifest()
            manifestStore.clear()
            packs = []
            state = .none
            await refreshCacheFigures()
            await refreshAttribution()
            isPruning = false
        }
    }

    /// Note a download so the storage screen can list it.
    private func record(_ pack: OfflinePack) {
        manifest.record(pack)
        persist()
    }

    private func persist() {
        manifestStore.save(manifest)
        packs = manifest.packs
    }

    /// Every tile a pack covers, rebuilt from the route it was downloaded for.
    private func keys(for pack: OfflinePack, route: Route? = nil) async -> [TileCacheKey] {
        let resolved = route ?? workspace?.routes.first { $0.id == Int(pack.id) }
        guard let resolved else { return [] }
        return tileKeys(
            for: resolved,
            sources: pack.sources.map(TileSourceRef.init),
            bufferMeters: pack.bufferMeters,
            zoomRange: pack.zoomRange
        )
    }
}

/// The part of a basemap source that a tile's identity needs.
///
/// Deliberately not `BasemapSource`: that carries the upstream template, which
/// belongs to the style and goes stale when the basemap changes, whereas a pack
/// record has to survive exactly that change to be able to list its tiles again.
struct TileSourceRef: Hashable {
    let name: String
    let format: TileFormat
    /// Elevation rather than map imagery, so it is asked for over the narrower
    /// range. Derived from the name for the same reason `BasemapSource.isElevation`
    /// is: the style's DEM source id is fixed.
    var isElevation: Bool { name == AppConfig.demSource }

    init(name: String, format: TileFormat) {
        self.name = name
        self.format = format
    }

    init(_ source: BasemapSource) {
        self.init(name: source.name, format: source.format)
    }

    init(_ source: OfflinePackSource) {
        self.init(name: source.name, format: source.format)
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
