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
}

/// Minimal actor counter, so a test can assert how many fetches happened.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
