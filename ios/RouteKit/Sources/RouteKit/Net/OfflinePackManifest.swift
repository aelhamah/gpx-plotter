import Foundation

/// One corridor the user deliberately downloaded, as opposed to tiles the cache
/// picked up as a side effect of browsing.
///
/// The cache is shared and self-warming: every tile the map asks for passes
/// through it, so most of what is on disk belongs to no route at all. That is
/// the right behaviour for a map and the wrong shape for a storage screen, which
/// has to answer "what did I download, and can I get rid of it?". This is the
/// record that lets it answer that without pretending the cache is nothing but
/// packs — the difference is reported as `unattributed` rather than hidden.
public struct OfflinePack: Codable, Hashable, Identifiable, Sendable {
    /// The workspace route id. Stable across launches, and the handle used to
    /// find the route again when the pack's tiles have to be listed for deletion.
    public var id: String
    /// Shown in the storage list, so it survives the route being renamed — which
    /// is why the name is a copy rather than a lookup.
    public var name: String
    public var tileCount: Int
    public var byteCount: Int
    public var downloadedAt: Date
    /// What was asked for, which is what makes the pack's tiles listable again.
    ///
    /// The route is *not* stored: a corridor is derivable from the route's points
    /// plus these three, so recording them is enough to delete precisely, without
    /// a second copy of the geometry.
    public var bufferMeters: Double
    /// The zoom range as two numbers, not a `ClosedRange`.
    ///
    /// `ClosedRange` is `Codable`, but through the standard library's own
    /// representation, which is a two-element array — so a manifest written as
    /// `{"lowerBound": 12, "upperBound": 14}` reads back as a type mismatch and,
    /// worse, quietly as *no packs at all*. Two integers in a file that people
    /// also read is worth the small loss of elegance.
    public var zoomLowerBound: Int
    public var zoomUpperBound: Int
    public var sources: [OfflinePackSource]

    public var zoomRange: ClosedRange<Int> { zoomLowerBound...zoomUpperBound }

    public init(
        id: String,
        name: String,
        tileCount: Int,
        byteCount: Int,
        downloadedAt: Date,
        bufferMeters: Double,
        zoomRange: ClosedRange<Int>,
        sources: [OfflinePackSource]
    ) {
        self.id = id
        self.name = name
        self.tileCount = tileCount
        self.byteCount = byteCount
        self.downloadedAt = downloadedAt
        self.bufferMeters = bufferMeters
        zoomLowerBound = zoomRange.lowerBound
        zoomUpperBound = zoomRange.upperBound
        self.sources = sources
    }
}

/// The basemap source a pack covered: the style's source id and the tile format,
/// which together with the coordinates make a `TileCacheKey`.
///
/// The upstream template is deliberately absent — it belongs to the style, not to
/// the download, and would go stale the moment the basemap changed.
public struct OfflinePackSource: Codable, Hashable, Sendable {
    public var name: String
    public var format: TileFormat

    public init(name: String, format: TileFormat) {
        self.name = name
        self.format = format
    }
}

/// What is deliberately downloaded, in one file.
///
/// Sorted by download time so the oldest is always first, which is the order
/// eviction wants and the order the storage screen shows.
public struct OfflinePackManifest: Codable, Hashable, Sendable {
    public private(set) var packs: [OfflinePack]

    public init(packs: [OfflinePack] = []) {
        self.packs = packs
    }

    /// Add a pack, or replace the one for the same route.
    ///
    /// Re-downloading a route moves it to the newest rather than adding a second
    /// entry: the tiles are the same keys, so two records would be one pack and
    /// two claims on the disk.
    public mutating func record(_ pack: OfflinePack) {
        packs.removeAll { $0.id == pack.id }
        packs.append(pack)
        sort()
    }

    @discardableResult
    public mutating func remove(id: String) -> OfflinePack? {
        guard let index = packs.firstIndex(where: { $0.id == id }) else { return nil }
        return packs.remove(at: index)
    }

    public func pack(id: String) -> OfflinePack? {
        packs.first { $0.id == id }
    }

    public var totalBytes: Int { packs.reduce(0) { $0 + $1.byteCount } }
    public var totalTiles: Int { packs.reduce(0) { $0 + $1.tileCount } }
    public var isEmpty: Bool { packs.isEmpty }

    /// Drop the oldest packs until the total is within `limit`.
    ///
    /// Returns what it dropped so the caller can delete those corridors' tiles as
    /// well — evicting the record without evicting the bytes would make the
    /// screen lie about what is on disk.
    @discardableResult
    public mutating func evict(over limit: Int) -> [OfflinePack] {
        var dropped: [OfflinePack] = []
        // Oldest first, and the list is newest-first, so that is the *end*. Taking
        // `first` here would evict the pack that was just downloaded — the one the
        // hiker asked for and the least likely to be the one they want gone.
        while totalBytes > limit, let oldest = packs.last {
            packs.removeLast()
            dropped.append(oldest)
        }
        return dropped
    }

    private mutating func sort() {
        packs.sort { $0.downloadedAt > $1.downloadedAt }
    }
}

/// The manifest on disk, next to the tiles.
///
/// A file of a few hundred bytes, read and written whole. Anything cleverer —
/// a database, an append-only log — would be bookkeeping for a document that
/// lists a handful of routes.
public struct OfflinePackManifestStore: Sendable {
    /// `Application Support/offline-packs.json`. Outside the tile directory on
    /// purpose: `TileCache.clear()` removes that directory wholesale, and a
    /// manifest inside it would delete the record of what to delete.
    public static var defaultURL: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("offline-packs.json")
    }

    private let url: URL?

    public init(url: URL? = OfflinePackManifestStore.defaultURL) {
        self.url = url
    }

    /// The stored manifest, or an empty one.
    ///
    /// A corrupt or unreadable file reads as "nothing downloaded" rather than
    /// throwing: the worst case is a storage screen that offers to re-download,
    /// which is recoverable, and refusing to launch over it is not.
    public func load() -> OfflinePackManifest {
        guard let url else { return OfflinePackManifest() }
        guard let data = try? Data(contentsOf: url) else { return OfflinePackManifest() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(OfflinePackManifest.self, from: data)
        } catch {
            // Logged rather than swallowed: reading as empty is the right
            // behaviour — a storage screen offering a re-download is recoverable,
            // refusing to launch is not — but a manifest that fails to decode with
            // no trace anywhere is how an hour gets lost. This is the only place
            // the file is read, so this is the only place it can be reported.
            print("[OfflinePacks] could not read \(url.path): \(error)")
            return OfflinePackManifest()
        }
    }

    public func save(_ manifest: OfflinePackManifest) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}