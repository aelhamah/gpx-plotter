import Foundation
import RouteKit

/// The elevation profile and the statistics, derived from **one** resampled
/// route so the chart and the numbers can never disagree.
///
/// This mirrors the web app, which resamples once at
/// `STATS_PROFILE_STEP_METERS` and then computes the stats, the profile chart,
/// and the distance along *all* from that same array (`updateRouteStats` in
/// `main.ts`). Computing the stats from the raw vertices instead is what makes
/// ascent and descent drift away from the chart on a track with dense fixes.
///
/// `Profile.routeSamples` carries elevation only on the original vertices — the
/// interpolated samples come back `nil` — so a track whose fixes are far apart
/// has a nearly empty profile. The web refills those from the DEM via
/// `elevationAt`; this does the same through `TerrainTileStore`.
@MainActor
final class RouteAnalysis: ObservableObject {
    /// Resampling step, matching the web app's `STATS_PROFILE_STEP_METERS`.
    static let stepMeters: Double = 30

    @Published private(set) var profile: RouteProfile
    /// True while the DEM lookups for the gaps are in flight.
    @Published private(set) var isFillingTerrain = false
    /// Set when the gaps could not be filled, so the UI can say why.
    @Published private(set) var terrainUnavailable = false

    private let store: TerrainTileStore
    private var fillTask: Task<Void, Never>?

    init(route: Route, store: TerrainTileStore? = nil) {
        self.profile = RouteProfile.make(from: route.points, stepMeters: Self.stepMeters)
        self.store = store ?? TerrainTileStore(config: AppConfig.terrainConfig)
    }

    deinit {
        fillTask?.cancel()
    }

    /// Fill the interpolated samples from MapTiler's Terrain-RGB tiles.
    ///
    /// Vertex elevations are never overwritten, so a GPX that carries its own
    /// elevation is trusted and only the gaps are looked up.
    func fillMissingElevations() {
        guard fillTask == nil, !isFillingTerrain else { return }
        guard AppConfig.terrainConfig != nil else {
            terrainUnavailable = true
            return
        }
        let gaps = profile.points.indices.filter { profile.points[$0].elevation == nil }
        guard !gaps.isEmpty else { return }

        isFillingTerrain = true
        let base = profile
        fillTask = Task { [store] in
            var filled = base.points
            var filledAny = false
            for index in gaps {
                if Task.isCancelled { return }
                let point = filled[index]
                let result = try? await store.elevationAt(lng: point.lon, lat: point.lat)
                if let elevation = result ?? nil {
                    filled[index] = RoutePoint(point.coordinate, elevation: elevation)
                    filledAny = true
                }
            }
            guard !Task.isCancelled else { return }
            self.profile = RouteProfile(
                points: filled,
                cumulativeDistances: base.cumulativeDistances,
                totalDistance: base.totalDistance
            )
            self.terrainUnavailable = !filledAny
            self.isFillingTerrain = false
            self.fillTask = nil
        }
    }

    // MARK: - Derived values

    /// Total distance along the resampled profile, in metres.
    var totalDistance: Double { profile.totalDistance }

    /// Gain, loss, and high point, from the same samples the chart draws.
    var elevation: ElevationStats { Slope.stats(for: profile.points) }

    /// Chart samples: every profile sample that has an elevation, at its true
    /// distance along the route.
    func samples(maxPoints: Int = 600) -> [ProfileSample] {
        ProfileSample.samples(from: profile, maxPoints: maxPoints)
    }
}
