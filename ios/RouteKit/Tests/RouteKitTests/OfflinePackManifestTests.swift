import XCTest
@testable import RouteKit

/// The manifest is what lets the storage screen say what was deliberately
/// downloaded, so the behaviour worth testing is the bookkeeping: one record per
/// route, totals that add up, and eviction that drops the oldest and says which.
final class OfflinePackManifestTests: XCTestCase {
    private func pack(
        id: String,
        name: String? = nil,
        bytes: Int = 1_000,
        tiles: Int = 10,
        daysAgo: Double = 0
    ) -> OfflinePack {
        OfflinePack(
            id: id,
            name: name ?? "Route \(id)",
            tileCount: tiles,
            byteCount: bytes,
            downloadedAt: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
            bufferMeters: Corridor.defaultBufferMeters,
            zoomRange: 12...14,
            sources: [OfflinePackSource(name: "outdoor", format: .pbf)]
        )
    }

    // MARK: - Recording

    func testRecordingSortsNewestFirst() {
        var manifest = OfflinePackManifest()
        manifest.record(pack(id: "old", daysAgo: 9))
        manifest.record(pack(id: "new"))
        manifest.record(pack(id: "middle", daysAgo: 3))
        XCTAssertEqual(manifest.packs.map(\.id), ["new", "middle", "old"])
    }

    /// The tiles are the same keys, so a second download of a route is one pack.
    func testRecordingTheSameRouteReplacesRatherThanDuplicates() {
        var manifest = OfflinePackManifest()
        manifest.record(pack(id: "a", bytes: 1_000, tiles: 10, daysAgo: 5))
        manifest.record(pack(id: "a", bytes: 2_000, tiles: 20))

        XCTAssertEqual(manifest.packs.count, 1)
        XCTAssertEqual(manifest.packs[0].byteCount, 2_000)
        XCTAssertEqual(manifest.packs[0].tileCount, 20)
        XCTAssertEqual(manifest.totalBytes, 2_000, "two records would claim the same tiles twice")
    }

    func testTotalsAddUp() {
        var manifest = OfflinePackManifest()
        manifest.record(pack(id: "a", bytes: 300, tiles: 3))
        manifest.record(pack(id: "b", bytes: 700, tiles: 7))
        XCTAssertEqual(manifest.totalBytes, 1_000)
        XCTAssertEqual(manifest.totalTiles, 10)
    }

    // MARK: - Removal

    func testRemovingReturnsTheRecordAndEmptiesTheManifest() {
        var manifest = OfflinePackManifest()
        manifest.record(pack(id: "a"))
        let removed = manifest.remove(id: "a")

        XCTAssertEqual(removed?.id, "a")
        XCTAssertTrue(manifest.isEmpty)
        XCTAssertNil(manifest.remove(id: "a"), "removing a pack twice is not a second removal")
    }

    // MARK: - Eviction

    func testEvictionDropsOldestFirstUntilUnderTheLimit() {
        var manifest = OfflinePackManifest()
        manifest.record(pack(id: "newest", bytes: 400))
        manifest.record(pack(id: "middle", bytes: 400, daysAgo: 5))
        manifest.record(pack(id: "oldest", bytes: 400, daysAgo: 10))

        let dropped = manifest.evict(over: 900)

        XCTAssertEqual(dropped.map(\.id), ["oldest"], "1,200 over a 900 limit drops the oldest 400")
        XCTAssertEqual(manifest.packs.map(\.id), ["newest", "middle"])
        XCTAssertEqual(manifest.totalBytes, 800)
    }

    func testEvictionKeepsGoingWhileOverTheLimit() {
        var manifest = OfflinePackManifest()
        for index in 0..<5 {
            manifest.record(pack(id: "\(index)", bytes: 1_000, daysAgo: Double(5 - index)))
        }

        let dropped = manifest.evict(over: 2_500)

        XCTAssertEqual(dropped.count, 3, "2,500 of 5,000 leaves two packs")
        XCTAssertEqual(manifest.packs.map(\.id), ["4", "3"])
    }

    func testEvictionUnderTheLimitDropsNothing() {
        var manifest = OfflinePackManifest()
        manifest.record(pack(id: "a", bytes: 100))
        XCTAssertTrue(manifest.evict(over: 1_000).isEmpty)
        XCTAssertEqual(manifest.packs.count, 1)
    }

    func testEvictingAnEmptyManifestIsHarmless() {
        var manifest = OfflinePackManifest()
        XCTAssertTrue(manifest.evict(over: 0).isEmpty)
        XCTAssertTrue(manifest.isEmpty)
    }

    // MARK: - Round trip

    /// The manifest is the only record of what to delete, so it has to survive
    /// the app being killed between sessions.
    func testManifestSurvivesAWriteAndARead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("packs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = OfflinePackManifestStore(url: url)
        var manifest = OfflinePackManifest()
        manifest.record(pack(id: "maroon", name: "Maroon Bells loop", bytes: 4_400_000, tiles: 68))
        manifest.record(pack(id: "twin", bytes: 900_000, tiles: 14))
        store.save(manifest)

        let read = store.load()
        XCTAssertEqual(read.packs.map(\.id), ["maroon", "twin"], "newest first, as saved")
        XCTAssertEqual(read.packs[0].name, "Maroon Bells loop")
        XCTAssertEqual(read.packs[0].byteCount, 4_400_000)
        XCTAssertEqual(read.totalBytes, 5_300_000)
    }

    func testReadingAMissingManifestIsEmptyRatherThanAnError() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        XCTAssertTrue(OfflinePackManifestStore(url: url).load().isEmpty)
    }

    /// A half-written or hand-edited file must not stop the app launching; the
    /// cost is a storage screen offering to re-download.
    func testReadingACorruptManifestIsEmptyRatherThanThrowing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json at all".utf8).write(to: url)

        XCTAssertTrue(OfflinePackManifestStore(url: url).load().isEmpty)
    }

    /// The shape of the file, pinned rather than round-tripped.
    ///
    /// A round-trip test passes whatever the encoder and decoder agree on, which
    /// is how a `ClosedRange` stored as a two-element array went unnoticed: the
    /// app wrote one shape and read it back happily, and the storage screen
    /// showed "No offline maps" against a file that plainly said otherwise. This
    /// decodes JSON written the way a person would write it.
    func testManifestDecodesFromAHandWrittenShape() throws {
        let json = """
        {
          "packs": [
            {
              "id": "1",
              "name": "Maroon Bells loop",
              "tileCount": 68,
              "byteCount": 4400000,
              "downloadedAt": "2026-10-14T17:20:22Z",
              "bufferMeters": 1000,
              "zoomLowerBound": 12,
              "zoomUpperBound": 14,
              "sources": [{ "name": "outdoor", "format": "pbf" }]
            }
          ]
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("handwritten-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)

        let manifest = OfflinePackManifestStore(url: url).load()

        XCTAssertEqual(manifest.packs.count, 1)
        XCTAssertEqual(manifest.packs.first?.name, "Maroon Bells loop")
        XCTAssertEqual(manifest.packs.first?.zoomRange, 12...14)
        XCTAssertEqual(manifest.packs.first?.sources.first?.name, "outdoor")
        XCTAssertEqual(manifest.totalBytes, 4_400_000)
    }

    /// And the file it writes has that shape, so the two cannot drift apart.
    func testSavedManifestUsesNamedZoomBounds() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shape-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = OfflinePackManifestStore(url: url)
        var manifest = OfflinePackManifest()
        manifest.record(pack(id: "a"))
        store.save(manifest)

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let packs = (object as? [String: Any])?["packs"] as? [[String: Any]]
        let first = packs?.first
        XCTAssertEqual(first?["zoomLowerBound"] as? Int, 12)
        XCTAssertEqual(first?["zoomUpperBound"] as? Int, 14)
        XCTAssertNil(first?["zoomRange"], "a ClosedRange would encode as an array, which reads back as no packs")
    }

    func testClearingRemovesTheFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleared-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = OfflinePackManifestStore(url: url)
        var manifest = OfflinePackManifest()
        manifest.record(pack(id: "a"))
        store.save(manifest)
        store.clear()

        XCTAssertTrue(store.load().isEmpty)
    }
}