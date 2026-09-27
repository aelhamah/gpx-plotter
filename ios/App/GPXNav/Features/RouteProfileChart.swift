import Charts
import SwiftUI
import RouteKit

/// Elevation profile for a route, drawn with Swift Charts.
///
/// Points come from the route's own vertices rather than a resampled
/// `RouteProfile`: resampling to a 30 m step keeps elevation only on the
/// original vertices, which would leave the line almost entirely empty. Where a
/// GPX has no elevation at all the chart says so instead of drawing a flat line.
struct RouteProfileChart: View {
    let route: Route
    let system: UnitSystem

    var body: some View {
        Group {
            if samples.count < 2 {
                unavailable
            } else {
                chart
            }
        }
        .frame(height: 140)
    }

    private var samples: [ProfileSample] {
        ProfileSample.samples(for: route)
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
        }
        // The axes carry raw metres; only the labels are converted, so the
        // plotted values stay in one unit.
        .chartYScale(domain: elevationDomain)
        .chartXAxis {
            AxisMarks { value in
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

    /// Vertical domain padded by 8% of the range at each end, matching
    /// `profileData` in the web app — anchoring at zero would flatten the shape.
    private var elevationDomain: ClosedRange<Double> {
        let elevations = samples.map(\.elevation)
        guard let low = elevations.min(), let high = elevations.max() else { return 0...1 }
        let padding = ((high - low) == 0 ? 1 : high - low) * 0.08
        return (low - padding)...(high + padding)
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
}

/// One point on the profile: distance along the route and elevation.
struct ProfileSample: Identifiable {
    let id: Int
    /// Meters from the start of the route.
    let distance: Double
    /// Meters above sea level.
    let elevation: Double

    /// Plot elevation against true distance along the route.
    ///
    /// Cumulative distance is accumulated over *every* vertex, so the x-axis
    /// spans the same total the stats bar reports. Only the drawn points are
    /// thinned, by keeping one per `step` metres — a raw GPS track can hold tens
    /// of thousands of fixes, and the profile shape is what matters, not every
    /// fix. Points without elevation are skipped rather than plotted as zero.
    static func samples(for route: Route, maxPoints: Int = 600) -> [ProfileSample] {
        let points = route.points
        guard points.count >= 2 else { return [] }

        let length = Haversine.routeLength(points)
        let budget = max(2, min(defaultPointBudget(distanceMeters: length, pointCount: points.count), maxPoints))
        let step = max(length / Double(budget), 1)

        var result: [ProfileSample] = []
        var cumulative = 0.0
        var nextSampleAt = 0.0
        for (index, point) in points.enumerated() {
            if index > 0 {
                cumulative += Haversine.meters(from: points[index - 1], to: point)
            }
            let isFirst = index == 0
            let isLast = index == points.count - 1
            guard let elevation = point.elevation,
                  isFirst || isLast || cumulative >= nextSampleAt
            else { continue }
            result.append(ProfileSample(id: result.count, distance: cumulative, elevation: elevation))
            nextSampleAt = cumulative + step
        }
        return result
    }
}
