import Charts
import SwiftUI
import RouteKit

/// Elevation profile for a route, drawn with Swift Charts.
///
/// The samples come from a `RouteAnalysis` profile, which is resampled at the web
/// app's 30 m step and refilled from terrain where the GPX had no elevation. The
/// statistics in the stats bar are computed from these same samples, so the two
/// always agree.
struct RouteProfileChart: View {
    @ObservedObject var analysis: RouteAnalysis
    let route: Route
    let system: UnitSystem
    /// Distance along the route currently scrubbed, which the map draws as a
    /// trace. Nil when nothing is scrubbed.
    @Binding var scrubbedDistance: Double?

    /// How many samples the chart draws.
    ///
    /// Each sample is two `Mark`s, and scrubbing re-renders every one of them on
    /// every frame of the drag, so this is the dominant cost of the gesture. The
    /// plot is about 340 pt wide and 130 pt tall, so 200 points is already more
    /// than one per device pixel across and the curve is indistinguishable from
    /// 600 — which was what made scrubbing stutter.
    ///
    /// The stats bar is unaffected: it reads the profile, not these samples.
    private static let chartSamples = 200

    var body: some View {
        let samples = analysis.samples(maxPoints: Self.chartSamples)
        VStack(spacing: 0) {
            if samples.count < 2 {
                unavailable
            } else {
                chart(samples)
                    // The chart used to fill this frame, so the x-axis labels
                    // and the area fill collided with the bottom edge.
                    .padding(.bottom, 14)
                    .padding(.top, 4)
            }
            footer(samples)
        }
        .frame(height: 170)
    }

    private func chart(_ samples: [ProfileSample]) -> some View {
        let domain = elevationDomain(samples)
        let points = ProfilePoint.pairs(from: samples)
        return Chart {
            // The baseline is stated rather than left implicit. An `AreaMark`
            // with a single `y` fills down to zero, and zero is *below* this
            // chart's y domain — a hiking route starts around 3,000 m — so the
            // fill was drawn hundreds of points under the plot area, unclipped,
            // as a pink slab over the rest of the panel. Anchoring it to the
            // domain's floor fills to the axis, which is what was wanted.
            ForEach(samples) { sample in
                AreaMark(
                    x: .value("Distance", sample.distance),
                    yStart: .value("Base", domain.lowerBound),
                    yEnd: .value("Elevation", sample.elevation)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [Color(hex: route.color).opacity(0.45), Color(hex: route.color).opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
            }

            // One line per segment, coloured by the avalanche slope band it falls
            // in — the same six bands as the on-map slope shading, so the chart
            // and the terrain agree about where the ground is steep. A single
            // `LineMark` in the route colour cannot show hazard at all.
            //
            // Collected into `points` first because `ChartContentBuilder` accepts
            // neither control flow nor `ForEach(_, id:)`; the trailing-closure
            // spelling is the one that binds to Charts' `ForEach`.
            ForEach(points) { point in
                LineMark(
                    x: .value("Distance", point.sample.distance),
                    y: .value("Elevation", point.sample.elevation),
                    series: .value("Segment", point.series)
                )
                .foregroundStyle(Color(hex: point.hex))
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            if let scrubbedDistance {
                RuleMark(x: .value("Scrubbed", scrubbedDistance))
                    .foregroundStyle(Color(hex: route.color).opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    // `y: .fit` so the readout flips below the rule near the top of
                    // the profile instead of escaping the plot and landing on the
                    // stats bar, which is what `y: .disabled` did.
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .fit)) {
                        readout(at: scrubbedDistance)
                    }
            }
        }
        // The axes carry raw metres; only the labels are converted, so the
        // plotted values stay in one unit.
        .chartYScale(domain: domain)
        // The chart proxy converts a touch position into a data value, so the
        // axis insets are accounted for. Estimating the plot width from the
        // screen instead put the trace in the wrong place whenever the axes
        // were not full width.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let origin = geometry[proxy.plotAreaFrame].origin
                                let x = value.location.x - origin.x
                                guard let distance: Double = proxy.value(atX: x) else { return }
                                scrubbedDistance = min(max(distance, 0), analysis.totalDistance)
                            }
                    )
            }
        }
        .chartXAxis {
            // Round distances, including the end of the route. Swift Charts' own
            // automatic ticks over a 3.42 mi profile gave 0.0 / 1.2 / 2.5 and
            // stopped well short of the finish.
            AxisMarks(values: xTicks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let meters = value.as(Double.self) {
                        Text(Units.formatDistanceAxis(meters, system: system))
                    }
                }
            }
        }
        .chartYAxis {
            // Round elevations. The same automatic pass produced 9,843 /
            // 10,171 / 10,499 ft over a 450 m climb.
            AxisMarks(position: .leading, values: yTicks(samples)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let meters = value.as(Double.self) {
                        Text(Units.formatElevation(meters, system: system))
                    }
                }
            }
        }
    }

    /// Distance ticks in metres, round in the unit the labels use.
    ///
    /// The route's finish is deliberately *not* forced onto the axis. Charts drops
    /// a label that would not fit past the plot edge, so a forced 3.4 mi label
    /// either disappears or collides with the last gridline — and an axis that
    /// simply ends where the line ends is what every printed profile does. The
    /// total is in the stats bar directly above.
    private var xTicks: [Double] {
        Units.niceDistanceTicks(
            inMeters: 0...analysis.totalDistance,
            system: system,
            targetCount: 4
        )
    }

    /// Elevation ticks in metres, round in the unit the labels use.
    private func yTicks(_ samples: [ProfileSample]) -> [Double] {
        let elevations = samples.map(\.elevation)
        guard let low = elevations.min(), let high = elevations.max() else { return [] }
        let padding = ((high - low) == 0 ? 1 : high - low) * 0.08
        return Units.niceElevationTicks(
            inMeters: (low - padding)...(high + padding),
            system: system,
            targetCount: 5
        )
    }

    /// Distance, elevation, and grade at the scrubbed point.
    private func readout(at distance: Double) -> some View {
        let index = analysis.profile.index(nearestTo: distance)
        let point = analysis.profile.points[min(max(index, 0), analysis.profile.points.count - 1)]
        let elevation = Units.formatElevation(point.elevation, system: system)
        return Text("\(Units.formatDistance(distance, system: system)) · \(elevation)")
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
    }

    /// Why there is no line, and what is being done about it.
    @ViewBuilder
    private func footer(_ samples: [ProfileSample]) -> some View {
        if analysis.isFillingTerrain {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Filling elevation from terrain…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if analysis.terrainUnavailable {
            Text(AppConfig.terrainConfig == nil
                 ? "No terrain key, so missing elevations stay blank."
                 : "Terrain did not answer, so missing elevations stay blank.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if samples.count < 2, route.points.contains(where: { $0.elevation != nil }) {
            Text("Not enough elevation data to draw a profile.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if samples.count >= 2, scrubbedDistance == nil {
            // The chart is draggable and nothing about it says so; without this
            // the trace on the map looks like a feature nobody found.
            Text("Drag across the profile to trace your position on the map.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var unavailable: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.xyaxis.line")
                .foregroundStyle(.secondary)
            Text(route.points.contains { $0.elevation != nil }
                 ? "Not enough elevation data to draw a profile."
                 : "This GPX has no elevation data.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Vertical domain padded by 8% of the range at each end, matching
    /// `profileData` in the web app — anchoring at zero would flatten the shape.
    private func elevationDomain(_ samples: [ProfileSample]) -> ClosedRange<Double> {
        let elevations = samples.map(\.elevation)
        guard let low = elevations.min(), let high = elevations.max() else { return 0...1 }
        let padding = ((high - low) == 0 ? 1 : high - low) * 0.08
        return (low - padding)...(high + padding)
    }
}

/// A point of the profile prepared for drawing: where it is, which segment it
/// belongs to, and that segment's slope band.
///
/// `LineMark` has no two-dimensional segment initializer, so a coloured segment is
/// two marks sharing a `series` value. The series is the **segment index**, not the
/// band colour: Charts connects every point sharing a series in order, so keying on
/// the colour would draw a chord from the end of one green climb to the start of
/// the next one. Colour is applied per mark instead.
struct ProfilePoint: Identifiable {
    let id: Int
    let sample: ProfileSample
    /// Segment index, unique per segment.
    let series: Int
    /// The segment's avalanche band.
    let hex: String

    /// Two points per segment, in drawing order.
    static func pairs(from samples: [ProfileSample]) -> [ProfilePoint] {
        guard samples.count > 1 else { return [] }
        var points: [ProfilePoint] = []
        for index in 1..<samples.count {
            let series = index - 1
            let hex = SlopeBands.slopeBandColorHex(samples[index].slopeDegrees ?? 0)
            for sample in [samples[index - 1], samples[index]] {
                points.append(ProfilePoint(id: points.count, sample: sample, series: series, hex: hex))
            }
        }
        return points
    }
}

/// One point on the profile: distance along the route and elevation.
struct ProfileSample: Identifiable {
    let id: Int
    /// Meters from the start of the route.
    let distance: Double
    /// Meters above sea level.
    let elevation: Double
    /// Steepness of the segment ending at this sample, in degrees.
    ///
    /// Carried per sample rather than derived at draw time because the profile is
    /// thinned to ~200 points before it reaches the chart: the gradient of the
    /// thinned series and of the full one are not the same, and colouring the
    /// line by hazard band is only meaningful if the angle is the real one.
    let slopeDegrees: Double?

    /// Plot a resampled profile, keeping at most `maxPoints` of them.
    ///
    /// The x positions come from the profile's own cumulative distances, so
    /// thinning never moves a point: the line still spans the route's full
    /// length and stays consistent with the stats bar.
    ///
    /// Gradients are taken from the *full* profile before thinning, so a sample
    /// that survived keeps the steepness of the ground it actually covers.
    static func samples(from profile: RouteProfile, maxPoints: Int = 600) -> [ProfileSample] {
        let gradients = Self.slopeDegrees(from: profile)

        let withElevation = profile.points.indices.filter { profile.points[$0].elevation != nil }
        let kept: [Int]
        if withElevation.count > maxPoints {
            // Keep one sample per `stride`, always including the last so the line
            // reaches the end of the route.
            let stride = Double(withElevation.count) / Double(maxPoints)
            var indices: [Int] = []
            var nextIndex = 0.0
            for (offset, index) in withElevation.enumerated() {
                let isLast = offset == withElevation.count - 1
                guard isLast || Double(offset) >= nextIndex else { continue }
                indices.append(index)
                nextIndex = Double(offset) + stride
            }
            kept = indices
        } else {
            kept = withElevation
        }

        return kept.enumerated().map { offset, index in
            ProfileSample(
                id: offset,
                distance: profile.cumulativeDistances[index],
                elevation: profile.points[index].elevation!,
                slopeDegrees: gradients[index]
            )
        }
    }

    /// Angle of each profile segment, in degrees, indexed with the profile.
    ///
    /// `atan2(rise, run)` rather than a rise-over-run percentage so the value is
    /// already in the units `SlopeBands.slopeBandColorHex` expects. A segment with
    /// no horizontal run is 90°, not a division by zero.
    private static func slopeDegrees(from profile: RouteProfile) -> [Double?] {
        var result = [Double?](repeating: nil, count: profile.points.count)
        for index in 1..<profile.points.count {
            guard let from = profile.points[index - 1].elevation,
                  let to = profile.points[index].elevation
            else { continue }
            let run = profile.cumulativeDistances[index] - profile.cumulativeDistances[index - 1]
            result[index] = atan2(to - from, run) * 180 / .pi
        }
        return result
    }
}
