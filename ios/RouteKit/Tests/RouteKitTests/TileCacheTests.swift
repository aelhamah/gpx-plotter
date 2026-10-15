import XCTest
@testable import RouteKit

/// The cache is what makes the app usable with no network, so the behaviour that
/// matters is what happens on a *hit*: bytes come back off disk and the upstream
/// is never asked.
final class TileCacheTests: XCTestCase {
    private var directory: URL!
    private var cache: TileCache!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tilecache-\(UUID().uuidString)", isDirectory: true)
        cache = TileCache(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func key(_ source: String = "outdoor", _ z: Int = 12, _ x: Int = 656, _ y: Int = 1583) -> TileCacheKey {
        TileCacheKey(source: source, z: z, x: x, y: y)
    }

    /// Fails the test if it is ever called, which is how "no network on a hit" is
    /// asserted rather than assumed.
    private func unreachable() -> @Sendable (TileCacheKey) async throws -> Data {
        { _ in XCTFail("the cache went to the network on a hit"); return Data() }
    }

    // MARK: - The offline promise

    func testAStoredTileIsAnsweredWithoutTheNetwork() async throws {
        await cache.store(Data("basemap".utf8), for: key())

        let data = try await cache.data(for: key(), upstream: unreachable())
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "basemap")
    }

    /// A hit has to survive the process: the in-memory tier is a cache of the
    /// cache, and the disk tier is the one that makes a relaunch work offline.
    func testAStoredTileIsStillThereForAFreshCache() async throws {
        await cache.store(Data("basemap".utf8), for: key())
        let relaunched = TileCache(directory: directory)

        let data = try await relaunched.data(for: key(), upstream: unreachable())
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "basemap")
    }

    func testAMissFetchesStoresAndReturns() async throws {
        let data = try await cache.data(for: key()) { _ in Data("fetched".utf8) }

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "fetched")
        let second = try await cache.data(for: key(), upstream: unreachable())
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "fetched")
    }

    func testAFailedFetchIsNotCached() async throws {
        struct Boom: Error {}

        do {
            _ = try await cache.data(for: key()) { _ in throw Boom() }
            XCTFail("expected the failure to propagate")
        } catch {}

        let nilCache = await cache.cached(key())
        XCTAssertNil(nilCache, "a tile that failed to download must not be remembered")
    }

    // MARK: - Per-source identity

    /// The regression: a cache keyed by coordinates alone answers `contours` with
    /// `outdoor`'s bytes, so the map shows the wrong tiles and an offline
    /// download believes it fetched a tileset it never asked for.
    func testSourcesDoNotCollide() async throws {
        await cache.store(Data("outdoor".utf8), for: key("outdoor"))
        await cache.store(Data("contours".utf8), for: key("contours"))
        await cache.store(Data("labels".utf8), for: key("maptiler_planet"))

        for (source, expected) in [("outdoor", "outdoor"), ("contours", "contours"), ("maptiler_planet", "labels")] {
            let data = try await cache.data(for: key(source), upstream: unreachable())
            XCTAssertEqual(String(decoding: data, as: UTF8.self), expected, source)
        }
    }

    func testTheSameTileInTwoFormatsIsTwoTiles() async throws {
        await cache.store(Data("webp".utf8), for: TileCacheKey(source: "terrain", z: 14, x: 1, y: 2, format: .webp))
        await cache.store(Data("png".utf8), for: TileCacheKey(source: "terrain", z: 14, x: 1, y: 2, format: .png))

        let webp = try await cache.data(
            for: TileCacheKey(source: "terrain", z: 14, x: 1, y: 2, format: .webp),
            upstream: unreachable()
        )
        XCTAssertEqual(String(decoding: webp, as: UTF8.self), "webp")
    }

    // MARK: - Concurrency

    /// The map and a corridor download can want the same tile at the same moment;
    /// one request should reach the network, not two.
    func testConcurrentRequestsForOneTileShareOneFetch() async throws {
        let cache = try XCTUnwrap(cache)
        let tile = key()
        let fetches = Counter()
        let slowFetch: @Sendable (TileCacheKey) async throws -> Data = { _ in
            await fetches.increment()
            try await Task.sleep(for: .milliseconds(50))
            return Data("shared".utf8)
        }

        async let first = cache.data(for: tile, upstream: slowFetch)
        async let second = cache.data(for: tile, upstream: slowFetch)
        async let third = cache.data(for: tile, upstream: slowFetch)
        let results = try await [first, second, third]

        let fetchCount = await fetches.value
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(results.map { String(decoding: $0, as: UTF8.self) }, ["shared", "shared", "shared"])
    }

    // MARK: - Housekeeping

    func testFiguresCountWhatIsOnDisk() async throws {
        await cache.store(Data(repeating: 7, count: 100), for: key("outdoor"))
        await cache.store(Data(repeating: 7, count: 50), for: key("contours"))

        let tiles = await cache.tileCount()
        let bytes = await cache.byteCount()
        XCTAssertEqual(tiles, 2)
        XCTAssertEqual(bytes, 150)
    }

    func testClearEmptiesTheCache() async throws {
        await cache.store(Data("basemap".utf8), for: key())
        await cache.clear()

        let tiles = await cache.tileCount()
        XCTAssertEqual(tiles, 0)
        let nilCache = await cache.cached(key())
        XCTAssertNil(nilCache, "clear has to drop the in-memory tier too, not just the files")
    }

    /// The in-memory tier is a cache of the cache: over its budget the whole
    /// corpus is dropped and the disk tier takes over.
    func testTheMemoryTierIsBounded() async throws {
        let bounded = TileCache(directory: directory, memoryLimit: 100)
        await bounded.store(Data(repeating: 1, count: 60), for: key("outdoor", 12, 1, 1))
        await bounded.store(Data(repeating: 2, count: 60), for: key("outdoor", 12, 2, 2))

        // Dropped from memory, still on disk: the answer is the same either way.
        let data = try await bounded.data(for: key("outdoor", 12, 1, 1), upstream: unreachable())
        XCTAssertEqual(data.count, 60)
    }

    func testAnUnusableDirectoryIsReportedRatherThanCrashing() async throws {
        let broken = TileCache(directory: nil)
        let available = await broken.isAvailable
        XCTAssertFalse(available)

        await broken.store(Data("basemap".utf8), for: key())
        let nilCache = await broken.cached(key())
        XCTAssertNil(nilCache)
        let tiles = await broken.tileCount()
        XCTAssertEqual(tiles, 0)
    }
    // MARK: - Removing one pack's tiles

    /// Deleting a corridor must delete its tiles, and leave the rest of the cache
    /// readable: the cache is shared with the map the user is still looking at.
    func testRemovingKeysDeletesThoseTilesAndLeavesOthers() async {
        let a = key("outdoor", 12, 1, 1)
        let b = key("outdoor", 12, 2, 2)
        await cache.store(Data(repeating: 1, count: 100), for: a)
        await cache.store(Data(repeating: 2, count: 200), for: b)

        let removed = await cache.remove([a])
        XCTAssertEqual(removed, 1)
        let droppedHit = await cache.cached(a)
        XCTAssertNil(droppedHit)
        let survivor = await cache.cached(b)
        XCTAssertEqual(survivor?.count, 200)
    }

    func testRemovingAKeyThatIsNotThereIsNotAnError() async {
        let removed = await cache.remove([key("outdoor", 12, 9, 9)])
        XCTAssertEqual(removed, 0)
    }

    /// The failure this guards is a storage screen that says a corridor is gone
    /// while the map goes on drawing it out of the in-memory corpus.
    func testRemovedTilesStopBeingServedFromMemory() async {
        let key = key("outdoor", 12, 3, 3)
        await cache.store(Data(repeating: 7, count: 50), for: key)
        let hit = await cache.cached(key)
        XCTAssertEqual(hit?.count, 50, "stored, so it is in memory too")

        await cache.remove([key])
        let goneHit = await cache.cached(key)
        XCTAssertNil(goneHit)
    }

    /// Removing one source's tile must not remove another source's tile at the
    /// same coordinates -- the collision that `TileCacheKey` exists to prevent.
    func testRemovingOneSourceLeavesAnotherSourcesTileAtTheSameCoordinates() async {
        let contours = key("contours", 12, 4, 4)
        let outdoor = key("outdoor", 12, 4, 4)
        await cache.store(Data(repeating: 3, count: 10), for: contours)
        await cache.store(Data(repeating: 4, count: 10), for: outdoor)

        await cache.remove([contours])
        let gone = await cache.cached(contours)
        XCTAssertNil(gone)
        let survivor = await cache.cached(outdoor)
        XCTAssertEqual(survivor?.count, 10)
    }

    // MARK: - Measuring

    /// The storage screen attributes the cache to routes and reports the rest as
    /// unattributed, which only balances if a pack measures as its own bytes.
    func testMeasureReportsOnlyTheGivenKeys() async {
        let inside = key("outdoor", 12, 5, 5)
        let outside = key("outdoor", 12, 6, 6)
        let absent = key("outdoor", 12, 7, 7)
        await cache.store(Data(repeating: 9, count: 120), for: inside)
        await cache.store(Data(repeating: 9, count: 300), for: outside)

        let measured = await cache.measure([inside, absent])
        XCTAssertEqual(measured.tiles, 1, "a key with no file is not counted")
        XCTAssertEqual(measured.bytes, 120)
    }

    func testMeasureOfNothingIsZero() async {
        let none = await cache.measure([])
        XCTAssertEqual(none.tiles, 0)
        XCTAssertEqual(none.bytes, 0)
        let absent = await cache.measure([key()])
        XCTAssertEqual(absent.bytes, 0)
    }
}

/// Minimal actor counter, so a test can assert how many fetches happened.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
