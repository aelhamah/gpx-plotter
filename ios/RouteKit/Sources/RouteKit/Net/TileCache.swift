import Foundation

/// Disk-backed cache for the map's tiles.
///
/// This replaces `MLNOfflineStorage`, which on MapLibre Native 6.31.0 accepts a
/// corridor pack and then reports zero downloadable resources, so no tile is
/// ever fetched (docs/ios-plan.md §9). Fetching and storing the tiles ourselves
/// is the option the plan settled on.
///
/// The loopback server reads through this on every tile request, so simply
/// looking at an area warms the cache; a corridor download is then a bulk
/// prefetch of a region you intend to need rather than the only way to get
/// anything offline.
///
/// **A hit never touches the network.** That is the whole promise, and it is
/// what `data(for:upstream:)` is shaped around: the upstream closure is only
/// called on a miss, so a cached tile answers the request with the device
/// offline.
public actor TileCache {
    /// One tile's identity is a `TileCacheKey` — source, coordinates, and format.
    /// See that type for why the source is part of it.
    public enum CacheError: Error, LocalizedError {
        case noDirectory
        case upstreamFailed(Int)

        public var errorDescription: String? {
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
    private var memory: [TileCacheKey: Data] = [:]
    private var memoryBytes = 0
    private let memoryLimit: Int
    /// Fetches already in flight, so the map asking for a tile and the corridor
    /// download asking for the same one produce one request, not two.
    private var inFlight: [TileCacheKey: Task<Data, Error>] = [:]

    /// - Parameters:
    ///   - directory: where tiles live. Defaults to `Application Support/tiles`,
    ///     which is where the app wants them; tests pass a temporary directory.
    ///   - memoryLimit: bytes of decoded payloads to keep in memory before
    ///     dropping the lot. The corpus is dropped rather than evicted one entry
    ///     at a time, because a partial LRU is not worth its bookkeeping here.
    public init(directory: URL? = TileCache.defaultDirectory, memoryLimit: Int = 32 * 1024 * 1024) {
        if let directory {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            self.directory = directory
        } else {
            self.directory = nil
        }
        self.memoryLimit = memoryLimit
    }

    /// `Application Support/tiles`. iOS does not create `Application Support`
    /// until something asks for it, hence the `createDirectory` — without it the
    /// first write fails with "the folder doesn't exist".
    public static var defaultDirectory: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("tiles", isDirectory: true)
    }

    public var isAvailable: Bool { directory != nil }

    // MARK: - Reads

    /// Cached bytes, or nil on a miss.
    public func cached(_ key: TileCacheKey) -> Data? {
        if let hit = memory[key] { return hit }
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(key.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        remember(key, data)
        return data
    }

    /// Cached bytes, otherwise fetched from `upstream` and stored.
    ///
    /// The fetch-through is the point: the loopback server calls this on every
    /// tile request, so tiles land on disk as a side effect of looking at the
    /// map.
    public func data(
        for key: TileCacheKey,
        upstream: @Sendable @escaping (TileCacheKey) async throws -> Data
    ) async throws -> Data {
        if let hit = cached(key) { return hit }
        if let existing = inFlight[key] { return try await existing.value }

        let task = Task<Data, Error> { try await upstream(key) }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let data = try await task.value
        store(data, for: key)
        return data
    }

    // MARK: - Writes

    public func store(_ data: Data, for key: TileCacheKey) {
        guard let directory else { return }
        try? data.write(to: directory.appendingPathComponent(key.fileName), options: .atomic)
        remember(key, data)
    }

    // MARK: - Housekeeping

    /// Total bytes on disk.
    public func byteCount() -> Int {
        files.reduce(0) { total, url in
            total + (((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0)
        }
    }

    /// Number of tiles held.
    public func tileCount() -> Int {
        guard let directory else { return 0 }
        return (try? fileManager.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    /// Wipe the cache. LRU eviction is not implemented; the disk figure is shown
    /// in the UI so it is at least visible, and this is the escape hatch.
    public func clear() {
        guard let directory else { return }
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.removeAll()
        memoryBytes = 0
    }

    private var files: [URL] {
        guard let directory else { return [] }
        return (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
    }

    private func remember(_ key: TileCacheKey, _ data: Data) {
        memory[key] = data
        memoryBytes += data.count
        if memoryBytes > memoryLimit {
            memory.removeAll()
            memoryBytes = 0
        }
    }
}
