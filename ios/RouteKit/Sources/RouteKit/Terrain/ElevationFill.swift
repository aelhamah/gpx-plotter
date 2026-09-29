import Foundation

/// Filling the gaps in a resampled route's elevation series.
///
/// A resampled profile carries elevation only on the route's own vertices
/// (`Profile.routeSamples` leaves the interpolated samples `nil`), so something
/// has to complete the series, and the choice decides what the profile looks
/// like between the vertices.
///
/// The two available sources are the track itself and a terrain model, and they
/// are two different measurements of the same hillside. Asking the terrain model
/// for every gap, which is what the app used to do, is what put a dip at every
/// vertex: the vertex elevation, then terrain that disagrees with it, then the
/// next vertex. The disagreement on a hand-drawn route is hundreds of metres, so
/// the profile sawtoothed and the ascent total became the sum of the
/// disagreement rather than of a climb.
///
/// Interpolating between the track's own elevations instead fixes that, and costs
/// the real shape of the ground between the vertices — on a sparse route that is
/// the difference between a profile of the trail and a set of ramps between
/// points. `blended(terrain:track:)` keeps both: the terrain supplies the detail,
/// and the track's own elevations anchor it.
public enum ElevationFill {

    /// Whether a series has no usable elevation of its own, so the terrain model
    /// is the only thing that can fill it.
    public static func needsTerrain(_ values: [Double?]) -> Bool {
        !values.contains { $0?.isFinite == true }
    }

    /// Fill each missing elevation by interpolating between the nearest known
    /// ones on either side of it.
    ///
    /// This is the fallback for when the terrain model cannot be consulted, and it
    /// is all a track with no elevation of its own needs.
    ///
    /// A run at either end of the series has only one neighbour to work from, so
    /// it is held flat at that neighbour's value rather than extrapolated:
    /// inventing a slope there is how a profile grows a ramp that was never in
    /// the data.
    ///
    /// Values that are not finite count as missing, so a track that recorded
    /// `NaN` is treated like one that recorded nothing.
    public static func interpolating(_ values: [Double?]) -> [Double?] {
        let known = knownIndices(in: values)
        guard let first = known.first, let last = known.last else { return values }

        var filled = values
        for index in 0...first {
            filled[index] = values[first]
        }
        for index in last..<filled.count {
            filled[index] = values[last]
        }
        for (lower, upper) in zip(known, known.dropFirst()) where upper > lower + 1 {
            let from = values[lower]!
            let to = values[upper]!
            for index in (lower + 1)..<upper {
                let t = Double(index - lower) / Double(upper - lower)
                filled[index] = from + (to - from) * t
            }
        }
        return filled
    }

    /// The sample indices whose terrain value `blended(terrain:track:)` needs.
    ///
    /// Every gap, plus the samples with an elevation of their own that bound each
    /// run of them — those are where the correction from the terrain is anchored.
    /// Asking for the whole series would be a waste: a track with dense fixes has
    /// no gaps to fill, and a track with one gap does not need its other five
    /// thousand vertices measured.
    public static func terrainSamplesNeeded(track: [Double?]) -> [Int] {
        var needed: Set<Int> = []
        var index = 0
        while index < track.count {
            guard track[index]?.isFinite != true else {
                index += 1
                continue
            }
            let start = index
            while index < track.count, track[index]?.isFinite != true {
                needed.insert(index)
                index += 1
            }
            // The samples either side of the run, when they exist: the run's
            // correction is measured against them.
            if start > 0 { needed.insert(start - 1) }
            if index < track.count { needed.insert(index) }
        }
        return needed.sorted()
    }

    /// The terrain's own shape, corrected to pass through the elevations the
    /// track recorded.
    ///
    /// The terrain model knows the ground between the vertices and the track
    /// knows the ground at them, so each of the track's samples says how far
    /// above or below the terrain it put the route at that point. Carrying that
    /// correction across a run of gaps — interpolated, so it is continuous — keeps
    /// the real undulations between the vertices while making the series agree
    /// with the track everywhere the track has an opinion. Two sources that
    /// disagree cannot sawtooth when one is expressed as an offset from the
    /// other, which is what put a dip at every vertex when both were used raw.
    ///
    /// - Parameters:
    ///   - terrain: the terrain model's elevation per sample. Only the samples
    ///     from `terrainSamplesNeeded(track:)` have to be present; the rest are
    ///     ignored.
    ///   - track: the track's own elevation per sample.
    ///
    /// A sample with an elevation of its own keeps it, so the track is never
    /// overwritten. A gap whose terrain could not be read falls back to the
    /// track's own line between its vertices, so a failed lookup costs that one
    /// sample its detail and nothing else. A track with no elevation at all has
    /// nothing to anchor to, so the terrain is used as it stands.
    public static func blended(terrain: [Double?], track: [Double?]) -> [Double?] {
        let known = knownIndices(in: track)
        guard !known.isEmpty else { return terrain }

        // How far the track sits above or below the terrain, wherever both are
        // known. Interpolating this carries the correction across the gaps.
        var offsets = [Double?](repeating: nil, count: track.count)
        for index in known {
            guard index < terrain.count, let modelled = terrain[index], modelled.isFinite else { continue }
            offsets[index] = track[index]! - modelled
        }
        let correction = interpolating(offsets).map { $0 ?? 0 }
        let fallback = interpolating(track)

        return track.indices.map { index in
            if track[index]?.isFinite == true { return track[index] }
            let base = terrain.indices.contains(index) ? terrain[index] : nil
            let ground = (base?.isFinite == true ? base : fallback[index]) ?? 0
            return ground + correction[index]
        }
    }

    private static func knownIndices(in values: [Double?]) -> [Int] {
        values.indices.filter { values[$0]?.isFinite == true }
    }
}
