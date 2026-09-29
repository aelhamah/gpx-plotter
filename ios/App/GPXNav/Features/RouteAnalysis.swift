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
/// interpolated samples come back `nil` — so `fillMissingElevations` completes
/// the series from the terrain model, anchored to the elevations the track
/// already carries. See `ElevationFill` for why the two are blended rather than
/// used raw.
@MainActor
final class RouteAnalysis: ObservableObject {
    /// Resampling step, matching the web app's `STATS_PROFILE_STEP_METERS`.
    static let stepMeters: Double = 30

    @Published private(set) var profile: RouteProfile
    /// True while the DEM lookups for a track with no elevation are in flight.
    @Published private(set) var isFillingTerrain = false
    /// Set when the terrain could not be reached, so the UI can say why.
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

    /// Complete the profile's elevation series.
    ///
    /// The terrain model supplies the ground between the route's vertices, and
    /// the track's own elevations anchor it: each of the track's samples says how
    /// far above or below the terrain it put the route, and that correction is
    /// carried across the gaps. Two sources cannot sawtooth against each other
    /// when one is expressed as an offset from the other, which is what put a dip
    /// in the profile at every vertex when both were used raw.
    ///
    /// Vertex elevations are never overwritten, and a failed terrain lookup costs
    /// that one sample its detail rather than the profile its shape: the
    /// interpolation between the track's own elevations is the fallback. A GPX
    /// with no `<ele>` at all is the case the terrain model is for, and it is
    /// used as it stands.
    func fillMissingElevations() {
        guard fillTask == nil, !isFillingTerrain else { return }
        let track = profile.points.map(\.elevation)
        let gaps = profile.points.indices.filter { profile.points[$0].elevation == nil }
        guard !gaps.isEmpty else { return }
        guard AppConfig.terrainConfig != nil else {
            // No terrain to ask: the track's own line between its vertices is
            // what is left, and it is better than a profile of bare samples.
            apply(ElevationFill.interpolating(track))
            return
        }

        isFillingTerrain = true
        let base = profile
        fillTask = Task { [store] in
            // Every gap, plus the samples that bound each run of them: the
            // correction that carries the track's elevations across the gaps is
            // measured against those, so a track's terrain is never fetched for
            // vertices that no gap depends on.
            let wanted = ElevationFill.terrainSamplesNeeded(track: track)
            let gaps = Set(gaps)
            var terrain = [Double?](repeating: nil, count: track.count)
            var answered = 0
            for index in wanted {
                if Task.isCancelled { return }
                let point = base.points[index]
                if let elevation = try? await store.elevationAt(lng: point.lon, lat: point.lat) {
                    terrain[index] = elevation
                    if gaps.contains(index) { answered += 1 }
                }
            }
            guard !Task.isCancelled else { return }
            self.apply(ElevationFill.blended(terrain: terrain, track: track))
            self.terrainUnavailable = answered == 0
            self.isFillingTerrain = false
            self.fillTask = nil
        }
    }

    /// Replace the profile's elevations, keeping its distances.
    private func apply(_ values: [Double?]) {
        let points = zip(profile.points, values).map { point, elevation in
            RoutePoint(point.coordinate, elevation: elevation)
        }
        profile = RouteProfile(
            points: points,
            cumulativeDistances: profile.cumulativeDistances,
            totalDistance: profile.totalDistance
        )
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
