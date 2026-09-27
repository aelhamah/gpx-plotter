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

    static func grouped(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}