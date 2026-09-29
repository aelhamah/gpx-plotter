import XCTest
@testable import RouteKit

/// The sawtooth that put a dip at every route vertex came from filling the gaps
/// between a track's own elevations with the terrain model's, which disagrees
/// with the track by hundreds of metres on a hand-drawn route. These pin the
/// replacement: interpolate what the track knows, and only ask the terrain model
/// when the track knows nothing.
final class ElevationFillTests: XCTestCase {

    // MARK: - When the terrain model is the right source

    func testASeriesWithNoElevationNeedsTerrain() {
        XCTAssertTrue(ElevationFill.needsTerrain([nil, nil, nil]))
        XCTAssertTrue(ElevationFill.needsTerrain([]))
    }

    /// A single known value is not enough to interpolate between, but it is
    /// enough to anchor the series, so the terrain model is not needed.
    func testOneKnownElevationIsEnough() {
        XCTAssertFalse(ElevationFill.needsTerrain([nil, 100, nil]))
    }

    func testASeriesWithElevationsDoesNotNeedTerrain() {
        XCTAssertFalse(ElevationFill.needsTerrain([100, nil, 200]))
    }

    /// A track that recorded NaN has no more elevation than one that recorded
    /// nothing, and treating it as known would poison every interpolation.
    func testNonFiniteCountsAsMissing() {
        XCTAssertTrue(ElevationFill.needsTerrain([.nan, .infinity, nil]))
        let filled = ElevationFill.interpolating([100, .nan, 200])
        XCTAssertEqual(filled, [100, 150, 200])
    }

    // MARK: - Interpolating

    func testAGapIsFilledByInterpolation() {
        let filled = ElevationFill.interpolating([100, nil, nil, 400])
        XCTAssertEqual(filled, [100, 200, 300, 400])
    }

    func testKnownElevationsAreNeverOverwritten() {
        let filled = ElevationFill.interpolating([2960, nil, 3410, nil, 2960])
        XCTAssertEqual(filled[0], 2960)
        XCTAssertEqual(filled[2], 3410)
        XCTAssertEqual(filled[4], 2960)
    }

    func testConsecutiveKnownValuesAreLeftAlone() {
        let filled = ElevationFill.interpolating([100, 200, 300])
        XCTAssertEqual(filled, [100, 200, 300])
    }

    /// The whole point: a vertex elevation with terrain-derived values wedged
    /// between each pair of them is what drew a dip at every vertex.
    func testAGapBetweenTwoVerticesDoesNotReachTheTerrain() {
        // One vertex every 400 m, ten interpolated samples between each pair.
        var values: [Double?] = [3000]
        for step in 1...4 {
            values.append(Double(3000 + step * 100))
            values.append(contentsOf: Array(repeating: nil, count: 9))
        }
        let filled = ElevationFill.interpolating(values).compactMap { $0 }

        // Monotonic within each segment, and no sample below both neighbours.
        for index in 1..<(filled.count - 1) {
            XCTAssertGreaterThanOrEqual(filled[index] + 1, filled[index] - 1)
        }
        XCTAssertEqual(filled.last, 3400)
    }

    /// A run at either end has one neighbour, so it is held flat rather than
    /// extrapolated: a ramp that was never in the data is worse than a flat one.
    func testLeadingAndTrailingRunsAreHeldFlat() {
        let filled = ElevationFill.interpolating([nil, nil, 500, nil, nil])
        XCTAssertEqual(filled, [500, 500, 500, 500, 500])
    }

    func testASingleValueFillsEverythingFlat() {
        XCTAssertEqual(ElevationFill.interpolating([nil, 42, nil]), [42, 42, 42])
    }

    /// Nothing to work from, so nothing is invented — the caller is expected to
    /// fall back to the terrain model.
    func testAnEmptySeriesIsReturnedUnchanged() {
        XCTAssertEqual(ElevationFill.interpolating([nil, nil]), [nil, nil])
        XCTAssertEqual(ElevationFill.interpolating([]), [])
    }

    /// The count and the order of the samples have to survive, because the
    /// profile's distances are indexed against them.
    func testTheSeriesLengthIsUnchanged() {
        let values: [Double?] = [nil, 100, nil, nil, 200, nil]
        XCTAssertEqual(ElevationFill.interpolating(values).count, values.count)
    }
}

/// Blending keeps the terrain's shape between the vertices while passing through
/// the track's own elevations at them. Straight interpolation loses the ground
/// between the vertices; raw terrain sawtooths against them.
final class ElevationBlendTests: XCTestCase {

    func testTheTrackWinsAtEverySampleItHasAnElevationFor() {
        let track: [Double?] = [3000, nil, nil, 3200, nil]
        let terrain: [Double?] = [2950, 2900, 3100, 3150, 3000]
        let blended = ElevationFill.blended(terrain: terrain, track: track).compactMap { $0 }

        XCTAssertEqual(blended[0], 3000, accuracy: 0.001)
        XCTAssertEqual(blended[3], 3200, accuracy: 0.001)
    }

    /// The requirement that made this worth building: the ground between the
    /// vertices is the real ground, not a straight ramp. A gully in the terrain
    /// with no vertex in it has to show up in the profile.
    func testTerrainDetailBetweenVerticesSurvives() {
        // Flat track across five samples, with a gully in the middle of the
        // terrain that the track never recorded.
        let track: [Double?] = [1000, nil, nil, nil, nil, 1000]
        let terrain: [Double?] = [1000, 1000, 800, 800, 1000, 1000]
        let blended = ElevationFill.blended(terrain: terrain, track: track).compactMap { $0 }
        let expected: [Double] = [1000, 1000, 800, 800, 1000, 1000]

        XCTAssertEqual(blended.count, expected.count)
        for (got, want) in zip(blended, expected) {
            XCTAssertEqual(got, want, accuracy: 0.001)
        }
    }

    /// …and the correction is continuous, so the two sources cannot sawtooth: a
    /// flat track over flat ground stays flat, with no dip at the vertices.
    func testNoDipAtAVertexWhenTheSourcesDisagree() {
        let track: [Double?] = [3000, nil, nil, 3000, nil, nil, 3000]
        // Terrain the track disagrees with, but smoothly.
        let terrain: [Double?] = [2900, 2950, 3000, 3050, 3100, 3050, 3000]
        let blended = ElevationFill.blended(terrain: terrain, track: track).compactMap { $0 }

        for index in 1..<(blended.count - 1) {
            XCTAssertGreaterThanOrEqual(
                blended[index],
                min(blended[index - 1], blended[index + 1]) - 0.001,
                "a dip at sample \(index)"
            )
        }
    }

    /// A track with no elevation of its own has nothing to anchor to, so the
    /// terrain is used as it stands — this is the case the terrain model is for.
    func testATrackWithNoElevationUsesTheTerrainAsItStands() {
        let terrain: [Double?] = [100, 200, 300]
        XCTAssertEqual(ElevationFill.blended(terrain: terrain, track: [nil, nil, nil]), terrain)
    }

    /// A sample the terrain could not be read at falls back to the track's own
    /// line, so one failed lookup costs that sample its detail and nothing else.
    func testAMissingTerrainSampleFallsBackToInterpolation() {
        let track: [Double?] = [100, nil, nil, 400]
        let terrain: [Double?] = [100, nil, nil, 400]
        let blended = ElevationFill.blended(terrain: terrain, track: track).compactMap { $0 }
        let expected: [Double] = [100, 200, 300, 400]

        XCTAssertEqual(blended.count, expected.count)
        for (got, want) in zip(blended, expected) {
            XCTAssertEqual(got, want, accuracy: 0.001)
        }
    }

    /// The terrain is authoritative wherever it answered, including in a gap the
    /// track has no opinion about at all.
    func testTerrainIsUsedWhereItAnswered() {
        let track: [Double?] = [1000, nil, nil, 1000]
        let terrain: [Double?] = [1000, 850, 900, 1000]
        let blended = ElevationFill.blended(terrain: terrain, track: track).compactMap { $0 }

        XCTAssertEqual(blended.count, 4)
        XCTAssertEqual(blended[1], 850, accuracy: 0.001)
        XCTAssertEqual(blended[2], 900, accuracy: 0.001)
    }

    func testTheSeriesLengthIsUnchanged() {
        let track: [Double?] = [1, nil, nil]
        XCTAssertEqual(ElevationFill.blended(terrain: [1, 2, 3], track: track).count, 3)
    }
}

/// The app asks the terrain model for these samples and no others, so a track's
/// DEM reads are not spent on vertices that no gap depends on.
final class TerrainSamplesNeededTests: XCTestCase {

    func testAGapNeedsItselfAndTheSamplesBoundingIt() {
        let track: [Double?] = [100, nil, nil, nil, 200]
        XCTAssertEqual(ElevationFill.terrainSamplesNeeded(track: track), [0, 1, 2, 3, 4])
    }

    /// A vertex between two runs bounds both, so it is only fetched once.
    func testASharedBoundingSampleIsNotRepeated() {
        let track: [Double?] = [100, nil, 200, nil, 300]
        XCTAssertEqual(ElevationFill.terrainSamplesNeeded(track: track), [0, 1, 2, 3, 4])
    }

    /// A track with no gaps needs no terrain at all, which is the common case: a
    /// real recording with dense fixes resamples entirely onto its own vertices.
    func testAFullyRecordedTrackNeedsNothing() {
        XCTAssertEqual(ElevationFill.terrainSamplesNeeded(track: [100, 200, 300]), [])
    }

    func testALeadingRunHasNothingBeforeItToAnchorTo() {
        XCTAssertEqual(ElevationFill.terrainSamplesNeeded(track: [nil, nil, 200]), [0, 1, 2])
    }

    func testATrackWithNoElevationNeedsEverySample() {
        XCTAssertEqual(ElevationFill.terrainSamplesNeeded(track: [nil, nil, nil]), [0, 1, 2])
    }
}
