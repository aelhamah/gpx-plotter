import CoreLocation
import Foundation
import MapLibre
import RouteKit

/// Owns `MLNOfflineStorage` and exposes corridor packs.
///
/// The plan (§8) offers a corridor download on import: the route polyline plus
/// ~1 km of buffer, as an `MLNShapeOfflineRegion`. `MLNOfflineStorage` handles
/// LRU eviction and the ambient cache, so this type only has to translate a
/// route into a region and report progress.
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

    /// How long the pack may make no progress before we give up and say so.
    /// Without this a pack whose tile source cannot satisfy the requested zoom
    /// range sits in "preparing" forever.
    private let stallTimeout: TimeInterval = 20

    private let storage: MLNOfflineStorage

    /// Region the current pack covers, kept so it can be removed later.
    private var currentRegion: MLNShapeOfflineRegion?
    /// Zoom range the current pack was created with, for failure messages.
    private var currentZoomRange: ClosedRange<Int> = AppConfig.offlineZoomRange
    private var progressTimer: Timer?
    private var lastProgressChange = Date()
    private var lastResourceCount: UInt64 = .max
    /// Set once `addPack` reports back, so the stall timeout can tell "still
    /// waiting for MapLibre to accept the region" apart from "downloading but
    /// nothing is arriving".
    private var didStartDownloading = false

    init(storage: MLNOfflineStorage = .shared) {
        self.storage = storage
    }

    // MARK: - Estimate

    /// Compute the size and tile count for a route without downloading anything,
    /// so the UI can show a figure before the user commits.
    func estimate(
        for route: Route,
        bufferMeters: Double = Corridor.defaultBufferMeters,
        zoomRange: ClosedRange<Int> = AppConfig.offlineZoomRange
    ) {
        let imagery = Corridor.tiles(
            for: route.points.map(\.coordinate),
            bufferMeters: bufferMeters,
            zoomRange: zoomRange
        )
        let dem = Corridor.tiles(
            for: route.points.map(\.coordinate),
            bufferMeters: bufferMeters,
            zoomRange: Corridor.demZoomRange
        )
        estimatedTileCount = imagery.count + dem.count
        estimatedBytes = Corridor.estimatedBytes(for: imagery + dem)
    }

    /// Whether the current estimate is big enough to warrant a confirmation.
    var estimateIsLarge: Bool { estimatedBytes > 50_000_000 }

    // MARK: - Download

    /// Add a corridor pack for `route`. Replaces any pack this manager added before.
    func download(
        route: Route,
        styleURL: URL,
        bufferMeters: Double = Corridor.defaultBufferMeters,
        zoomRange: ClosedRange<Int> = AppConfig.offlineZoomRange
    ) {
        guard route.points.count >= 2 else {
            state = .failed("Route needs at least two points")
            return
        }

        removeCurrentPack()

        let ring = Corridor.shape(for: route.points.map(\.coordinate), bufferMeters: bufferMeters)
        guard ring.count >= 3 else {
            state = .failed("Could not build a download region for this route")
            return
        }

        estimate(for: route, bufferMeters: bufferMeters, zoomRange: zoomRange)

        let region = MLNShapeOfflineRegion(
            styleURL: styleURL,
            shape: MLNPolygon(
                coordinates: ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
                count: UInt(ring.count)
            ),
            fromZoomLevel: Double(zoomRange.lowerBound),
            toZoomLevel: Double(zoomRange.upperBound)
        )
        currentRegion = region
        currentZoomRange = zoomRange
        state = .preparing
        didStartDownloading = false
        // Arm the stall timer now, not in the `addPack` callback. MapLibre can
        // leave the pack in "preparing" without ever calling back, and a timer
        // that only starts on the callback would never fire.
        startPolling()

        // `MLNOfflinePack` is a non-Sendable ObjC class, so it must not be
        // retained, sent, or even captured. The pack is deliberately left
        // unnamed here and found later by matching its region.
        storage.addPack(for: region, withContext: Data()) { [weak self] _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.stopPolling()
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func startPolling() {
        progressTimer?.invalidate()
        lastProgressChange = Date()
        lastResourceCount = .max
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stopPolling() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// Give up on the current pack: stop polling, drop the pack so it does not
    /// linger in storage, and surface `message`.
    ///
    /// Removing matters because `addPack` succeeds even when MapLibre works out
    /// that the region needs no resources, so without this every failed attempt
    /// left another dead pack behind in the offline database.
    private func fail(_ message: String) {
        stopPolling()
        if let pack = currentPack() {
            storage.removePack(pack, withCompletionHandler: nil)
        }
        currentRegion = nil
        didStartDownloading = false
        state = .failed(message)
    }

    /// The pack for `currentRegion`, if MapLibre has it yet.
    ///
    /// Matching is by value, not by pointer: `MLNOfflinePack.region` does not
    /// hand back the very `MLNShapeOfflineRegion` that was passed in, so an
    /// identity check silently failed to find the pack and left the download
    /// stuck in "preparing".
    private func currentPack() -> MLNOfflinePack? {
        guard let region = currentRegion else { return nil }
        return storage.packs?.first { pack in
            guard let other = pack.region as? MLNShapeOfflineRegion,
                  let mine = region.shape as? MLNPolygon,
                  let theirs = other.shape as? MLNPolygon
            else { return false }
            // `MLNShapeOfflineRegion` exposes no bounding box, so the shape is
            // compared by coordinate.
            return other.styleURL == region.styleURL
                && other.minimumZoomLevel == region.minimumZoomLevel
                && other.maximumZoomLevel == region.maximumZoomLevel
                && polygonsMatch(mine, theirs)
        }
    }

    private func polygonsMatch(_ a: MLNPolygon, _ b: MLNPolygon) -> Bool {
        let count = Int(a.pointCount)
        guard count == Int(b.pointCount), count > 0 else { return false }
        let first = a.coordinates
        let second = b.coordinates
        for index in 0..<count {
            let lhs = first[index]
            let rhs = second[index]
            guard abs(lhs.latitude - rhs.latitude) < 1e-9,
                  abs(lhs.longitude - rhs.longitude) < 1e-9
            else { return false }
        }
        return true
    }

    private func poll() {
        guard let pack = currentPack() else {
            // Not in storage yet. Keep waiting, but only up to the stall
            // timeout, so a pack that never appears still ends as a failure.
            if Date().timeIntervalSince(lastProgressChange) > stallTimeout {
                fail(didStartDownloading
                    ? "The offline pack disappeared from storage."
                    : "MapLibre never started downloading this corridor.")
            }
            return
        }

        didStartDownloading = true
        switch pack.state {
        case .complete:
            stopPolling()
            state = .complete
        case .invalid:
            fail("Pack is no longer valid")
        default:
            let expected = pack.progress.countOfResourcesExpected
            let done = pack.progress.countOfResourcesCompleted

            if done != lastResourceCount {
                lastResourceCount = done
                lastProgressChange = Date()
            } else if Date().timeIntervalSince(lastProgressChange) > stallTimeout {
                // MapLibre reports an expected resource count of 0 and never
                // leaves `Inactive`, both with MapTiler's TileJSON-only style and
                // with the same style rewritten to inline `tiles`, and for both
                // polygon and bounding-box regions. So this is not the basemap
                // refusing the zoom range; MapLibre is not enumerating any
                // resources at all. See docs/ios-plan.md §8.
                fail(expected > 0
                    ? "No progress for \(Int(stallTimeout))s — the basemap may not serve this zoom range."
                    : "MapLibre reported no downloadable resources for this corridor at z\(currentZoomRange.lowerBound)–\(currentZoomRange.upperBound), so the offline pack cannot be built. Tracked in docs/ios-plan.md §8.")
                return
            }

            state = expected > 0
                ? .downloading(progress: Double(done) / Double(expected))
                : .preparing
        }
    }

    // MARK: - Removal

    func removeCurrentPack() {
        stopPolling()

        guard let pack = currentPack() else {
            state = .none
            currentRegion = nil
            didStartDownloading = false
            return
        }

        storage.removePack(pack) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.state = .none
            }
        }
        currentRegion = nil
        didStartDownloading = false
    }

    /// Format the estimate for display.
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
}
