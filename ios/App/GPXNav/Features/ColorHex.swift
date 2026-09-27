import SwiftUI

extension UIColor {
    /// "#rrggbb" → `UIColor`. Route colors come from `RouteKit.Colors`.
    convenience init(_ hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }

        var rgb: UInt64 = 0
        Scanner(string: value).scanHexInt64(&rgb)

        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// "#rrggbb" → `Color`, for SwiftUI chrome that mirrors a route color.
    init(hex: String) {
        self.init(uiColor: UIColor(hex))
    }
}
