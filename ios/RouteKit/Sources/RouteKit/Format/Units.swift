import Foundation

public enum UnitSystem: String, Codable, Sendable, CaseIterable, Identifiable {
    case metric
    case imperial
    public var id: String { rawValue }
}

public struct RGBAColor: Equatable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: Double

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// "#rrggbb" → RGBA, or `nil` for anything else.
    public init?(hex: String) {
        guard hex.count == 7, hex.first == "#",
              let value = UInt32(hex.dropFirst(), radix: 16)
        else { return nil }
        self.init(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF)
        )
    }

    /// "#rrggbb" with the given alpha, matching the translucent profile fill.
    public func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Unit conversion and display formatting. Numbers are never formatted inline in
/// the app — they go through here, as in `web/src/units.ts`.
public enum Units {
    public static let metersPerMile = 1609.344
    public static let metersPerKilometer = 1000.0
    public static let feetPerMeter = 3.280839895
    public static let missingValue = "—"

    public static func miles(_ meters: Double) -> Double { meters / metersPerMile }
    public static func kilometers(_ meters: Double) -> Double { meters / metersPerKilometer }
    public static func feet(_ meters: Double) -> Double { meters * feetPerMeter }

    /// Preferred units: imperial when the user's locale resolves to the US, metric otherwise.
    public static func defaultUnitSystem(locale: Locale = .current) -> UnitSystem {
        locale.region?.identifier == "US" ? .imperial : .metric
    }

    public static func formatDistance(_ meters: Double, system: UnitSystem) -> String {
        switch system {
        case .imperial: return String(format: "%.2f mi", miles(meters))
        case .metric: return String(format: "%.2f km", kilometers(meters))
        }
    }

    public static func formatElevation(_ meters: Double?, system: UnitSystem, locale: Locale = .current) -> String {
        guard let meters, meters.isFinite else { return missingValue }
        switch system {
        case .imperial: return "\(grouped(Int(feet(meters).rounded()), locale: locale)) ft"
        case .metric: return "\(grouped(Int(meters.rounded()), locale: locale)) m"
        }
    }

    public static func formatSlope(_ degrees: Double?) -> String {
        guard let degrees, degrees.isFinite else { return missingValue }
        return "\(Int(degrees.rounded()))°"
    }

    /// Axis tick label: one decimal below 10 units, rounded above.
    public static func formatDistanceAxis(_ meters: Double, system: UnitSystem) -> String {
        let value = system == .imperial ? miles(meters) : kilometers(meters)
        return value < 10 ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
    }

    /// Round axis ticks covering `range`, at a spacing a person would pick.
    ///
    /// Chart frameworks choose their own ticks, and over a domain like a route's
    /// elevation they produce values nobody would write down — a 3.42 mi loop
    /// from 2,960 m to 3,410 m came out as 0.0 / 1.2 / 2.5 mi and
    /// 9,843 / 10,171 / 10,499 ft. Steps come from 1, 2, 2.5 and 5 times a power
    /// of ten, so the same profile reads 0, 0.6, 1.2 … and 2,900 / 3,000 / 3,100 m.
    ///
    /// Every tick is a whole number of steps from zero, which is what keeps the
    /// labels round. `range` may be in any unit; it is only read to choose a step.
    public static func niceTicks(in range: ClosedRange<Double>, targetCount: Int = 5) -> [Double] {
        let low = min(range.lowerBound, range.upperBound)
        let high = max(range.lowerBound, range.upperBound)
        let span = high - low
        guard span > 0, span.isFinite, targetCount > 1 else { return [] }

        let rough = span / Double(targetCount - 1)
        guard rough > 0, rough.isFinite else { return [] }
        let magnitude = pow(10, (log10(rough)).rounded(.down))

        // Every candidate step is scored on the number of ticks it actually
        // produces, rather than rounding `rough` in one direction. Rounding up
        // alone is worse than the framework's own choice: over 0…5,486 m a rough
        // step of 1,371 m rounds up to 2,000 and leaves three gridlines instead
        // of six.
        var best: (count: Int, step: Double)?
        for mantissa in [1.0, 2.0, 2.5, 5.0, 10.0] {
            let step = mantissa * magnitude
            guard step > 0, step.isFinite else { continue }
            let count = tickCount(low: low, high: high, step: step)
            guard count >= 2 else { continue }
            // Ties go to the larger step, i.e. the sparser grid.
            if best == nil
                || abs(count - targetCount) < abs(best!.count - targetCount)
                || (abs(count - targetCount) == abs(best!.count - targetCount) && count < best!.count) {
                best = (count, step)
            }
        }
        guard let best else { return [] }

        let first = (low / best.step).rounded(.down) * best.step
        let decimals = decimals(for: best.step)
        let scale = pow(10, Double(decimals))

        // Indexed, then rounded to the step's own precision. Neither step alone is
        // enough: accumulating `step` drifts, and even `first + i * step` renders
        // the fourth 0.2 step as 0.6000000000000001.
        return (0..<best.count).map {
            ((first + Double($0) * best.step) * scale).rounded() / scale
        }
    }

    /// How many ticks of `step` cover `low...high`.
    private static func tickCount(low: Double, high: Double, step: Double) -> Int {
        let first = (low / step).rounded(.down) * step
        let last = ((high - first) / step).rounded(.down)
        guard last >= 0, last.isFinite else { return 0 }
        return Int(last) + 1
    }

    /// Decimal places `step` needs to be written exactly.
    ///
    /// A step of 2.5 needs one despite being of order 10⁰, hence the check rather
    /// than a plain `-floor(log10(step))`.
    private static func decimals(for step: Double) -> Int {
        var places = max(0, Int(-log10(step).rounded(.down)))
        while places < 9 {
            let scaled = step * pow(10, Double(places))
            if abs(scaled - scaled.rounded()) < 1e-9 { break }
            places += 1
        }
        return places
    }

    /// Elevation ticks to label an axis with, returned in **metres** so they can be
    /// plotted against a metre-based profile.
    ///
    /// The ticks are chosen in the unit that will actually be *printed*. Choosing
    /// them in metres and labelling in feet gives a round-looking axis that reads
    /// 9,186 / 9,843 / 10,499 ft, because 2,800 m is a tidy number of metres and
    /// nothing at all as feet.
    public static func niceElevationTicks(
        inMeters range: ClosedRange<Double>,
        system: UnitSystem,
        targetCount: Int = 5
    ) -> [Double] {
        guard range.upperBound > range.lowerBound else { return [] }
        switch system {
        case .imperial:
            return niceTicks(
                in: feet(range.lowerBound)...feet(range.upperBound),
                targetCount: targetCount
            ).map { $0 / feetPerMeter }
        case .metric:
            return niceTicks(in: range, targetCount: targetCount)
        }
    }

    /// Distance ticks to label an axis with, returned in **metres**.
    ///
    /// Same reason as `niceElevationTicks`: 1,000 m steps read as 0.6 / 1.2 / 1.9
    /// mi, which is a grid nobody would draw on a hiking map.
    public static func niceDistanceTicks(
        inMeters range: ClosedRange<Double>,
        system: UnitSystem,
        targetCount: Int = 4
    ) -> [Double] {
        guard range.upperBound > range.lowerBound else { return [] }
        switch system {
        case .imperial:
            return niceTicks(
                in: miles(range.lowerBound)...miles(range.upperBound),
                targetCount: targetCount
            ).map { $0 * metersPerMile }
        case .metric:
            return niceTicks(in: range, targetCount: targetCount)
        }
    }

    /// Thousands-separated integer, for point counts as well as elevations.
    public static func grouped(_ value: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}