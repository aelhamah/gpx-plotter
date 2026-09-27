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

    var body: some View {
        VStack(spacing: 0) {
            if samples.count < 2 {
                unavailable
            } else {
                chart
                    // The chart used to fill this frame, so the x-axis labels
                    // and the area fill collided with the bottom edge.
                    .padding(.bottom, 14)
                    .padding(.top, 4)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture)
            }
            footer
        }
        .frame(height: 170)
    }

    /// Drag along the profile to trace the position onto the map.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard samples.count > 1 else { return }
                let fraction = min(max(value.location.x / max(plotWidth, 1), 0), 1)
                scrubbedDistance = fraction * (analysis.totalDistance)
            }
            .onEnded { _ in
                // Leave the trace where it was dropped; tapping elsewhere clears
                // it. Matches the web app, which keeps the trace on the map.
            }
    }

    /// Approximate plot width, used to turn a drag position into a distance.
    private var plotWidth: CGFloat {
        UIScreen.main.bounds.width - 48
    }

    private var samples: [ProfileSample] {
        analysis.samples()
    }

    private var chart: some View {
        Chart(samples) { sample in
            AreaMark(
                x: .value("Distance", sample.distance),
                y: .value("Elevation", sample.elevation)
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [Color(hex: route.color).opacity(0.45), Color(hex: route.color).opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Distance", sample.distance),
                y: .value("Elevation", sample.elevation)
            )
            .foregroundStyle(Color(hex: route.color))
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.monotone)

            if let scrubbedDistance {
                RuleMark(x: .value("Scrubbed", scrubbedDistance))
                    .foregroundStyle(Color(hex: route.color).opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        readout(at: scrubbedDistance)
                    }
            }
        }
        // The axes carry raw metres; only the labels are converted, so the
        // plotted values stay in one unit.
        .chartYScale(domain: elevationDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let meters = value.as(Double.self) {
                        Text(Units.formatDistanceAxis(meters, system: system))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let meters = value.as(Double.self) {
                        Text(Units.formatElevation(meters, system: system))
                    }
                }
            }
        }
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
    private var footer: some View {
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
    private var elevationDomain: ClosedRange<Double> {
        let elevations = samples.map(\.elevation)
        guard let low = elevations.min(), let high = elevations.max() else { return 0...1 }
        let padding = ((high - low) == 0 ? 1 : high - low) * 0.08
        return (low - padding)...(high + padding)
    }
}

/// One point on the profile: distance along the route and elevation.
struct ProfileSample: Identifiable {
    let id: Int
    /// Meters from the start of the route.
    let distance: Double
    /// Meters above sea level.
    let elevation: Double

    /// Plot a resampled profile, keeping at most `maxPoints` of them.
    ///
    /// The x positions come from the profile's own cumulative distances, so
    /// thinning never moves a point: the line still spans the route's full
    /// length and stays consistent with the stats bar.
    static func samples(from profile: RouteProfile, maxPoints: Int = 600) -> [ProfileSample] {
        let withElevation = profile.points.indices.filter { profile.points[$0].elevation != nil }
        guard withElevation.count > maxPoints else {
            return withElevation.enumerated().map { offset, index in
                ProfileSample(
                    id: offset,
                    distance: profile.cumulativeDistances[index],
                    elevation: profile.points[index].elevation!
                )
            }
        }

        // Keep one sample per `stride`, always including the last so the line
        // reaches the end of the route.
        let stride = Double(withElevation.count) / Double(maxPoints)
        var result: [ProfileSample] = []
        var nextIndex = 0.0
        for (offset, index) in withElevation.enumerated() {
            let isLast = offset == withElevation.count - 1
            guard isLast || Double(offset) >= nextIndex else { continue }
            result.append(ProfileSample(
                id: result.count,
                distance: profile.cumulativeDistances[index],
                elevation: profile.points[index].elevation!
            ))
            nextIndex = Double(offset) + stride
        }
        return result
    }
}
