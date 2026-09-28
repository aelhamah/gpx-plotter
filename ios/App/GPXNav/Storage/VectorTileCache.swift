import Foundation

/// Disk-backed cache for basemap vector tiles.
///
/// This replaces `MLNOfflineStorage`, which on MapLibre Native 6.31.0 accepts a
/// corridor pack and then reports zero downloadable resources, so no tile is
/// ever fetched (docs/ios-plan.md §9). Fetching and storing the tiles ourselves
/// is the option the plan settled on.
///
/// The loopback server reads through this on every basemap request, so simply
/// looking at an area warms the cache; the corridor download is then a bulk
/// prefetch of a region you intend to need rather than the only way to get
/// anything offline.
actor VectorTileCache {
    /// One tile's identity, and its position on disk.
    struct Key: Hashable, Sendable, CustomStringConvertible {
        let z: Int
        let x: Int
        let y: Int

        var description: String { "\(z)/\(x)/\(y)" }

        /// `z/x/y.pbf` — MapTiler's vector tiles are protobuf.
        var fileName: String { "\(z)_\(x)_\(y).pbf" }
    }

    enum CacheError: Error, LocalizedError {
        case noDirectory
        case upstreamFailed(Int)

        var errorDescription: String? {
            switch self {
            case .noDirectory: return "Could not create the tile cache directory."
            case .upstreamFailed(let status): return "MapTiler returned HTTP \(status) for a tile."
            }
        }
    }

    private let directory: URL?
    private let fileManager = FileManager.default
    /// Tile payloads this session has already served, so a pan across the same
    /// tiles does not hit the disk each time.
    private var memory: [Key: Data] = [:]
    private var memoryBytes = 0
    private let memoryLimit = 32 * 1024 * 1024

    init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let base {
            let tiles = base.appendingPathComponent("tiles", isDirectory: true)
            try? fileManager.createDirectory(at: tiles, withIntermediateDirectories: true)
            directory = tiles
        } else {
            directory = nil
        }
    }

    var isAvailable: Bool { directory != nil }

    // MARK: - Reads

    /// Cached bytes, or nil on a miss.
    func cached(_ key: Key) -> Data? {
        if let hit = memory[key] { return hit }
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(key.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        remember(key, data)
        return data
    }

    /// Cached bytes, otherwise fetched from `upstream` and stored.
    ///
    /// The fetch-through is the whole point: the loopback server calls this on
    /// every basemap request, so tiles land on disk as a side effect of looking
    /// at the map.
    func data(for key: Key, upstream: @Sendable (Key) async throws -> Data) async throws -> Data {
        if let hit = cached(key) { return hit }
        let data = try await upstream(key)
        store(data, for: key)
        return data
    }

    // MARK: - Writes

    func store(_ data: Data, for key: Key) {
        guard let directory else { return }
        try? data.write(to: directory.appendingPathComponent(key.fileName), options: .atomic)
        remember(key, data)
    }

    // MARK: - Bulk prefetch

    /// Progress of a corridor prefetch.
    struct Progress: Sendable, Equatable {
        var completed: Int
        var total: Int
        var bytes: Int
        var isFinished: Bool { completed >= total }
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    /// Fetch and store many tiles, reporting after each one.
    ///
    /// Sequential on purpose: the upstream is a single MapTiler key, and a
    /// corridor's tiles are a handful of parallelisable requests, so flooding it
    /// buys little and risks the key's rate limit.
    func prefetch(
        _ keys: [Key],
        upstream: @Sendable (Key) async throws -> Data,
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async -> Progress {
        var progress = Progress(completed: 0, total: keys.count, bytes: 0)
        for key in keys {
            if Task.isCancelled { return progress }
            do {
                    let data = try await data(for: key, upstream: upstream)
                progress.completed += 1
                progress.bytes += data.count
            } catch {
                // A single failed tile should not abandon the corridor; count it
                // as done so progress still reaches the end, and the map falls
                // back to fetching it live.
                progress.completed += 1
            }
            onProgress(progress)
        }
        return progress
    }

    // MARK: - Housekeeping

    /// Total bytes on disk.
    func byteCount() -> Int {
        guard let directory,
              let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey]
              )
        else { return 0 }
        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Number of tiles held.
    func tileCount() -> Int {
        guard let directory else { return 0 }
        return (try? fileManager.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    /// Wipe the cache. LRU eviction is not implemented; the disk figure is shown
    /// in the UI so it is at least visible.
    func clear() {
        guard let directory else { return }
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.removeAll()
        memoryBytes = 0
    }

    private func remember(_ key: Key, _ data: Data) {
        memory[key] = data
        memoryBytes += data.count
        if memoryBytes > memoryLimit {
            memory.removeAll()
            memoryBytes = 0
        }
    }
}
