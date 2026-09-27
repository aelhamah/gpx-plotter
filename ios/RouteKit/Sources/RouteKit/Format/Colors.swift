/// Route line colors, kept identical to `web/src/colors.ts` so a workspace
/// imported from the web app renders in the same colors.
public enum Colors {
    public static let routePalette = [
        "#e11d48", "#2563eb", "#16a34a", "#d97706", "#9333ea", "#0f766e", "#dc2626",
    ]

    /// Profile-trace highlight on the map; kept distinct from every route default color.
    public static let trace = "#0ea5e9"

    /// Deterministic palette pick for a 1-based route id, wrapping when routes outnumber colors.
    public static func routeColor(forID id: Int) -> String {
        let count = routePalette.count
        let index = (((id - 1) % count) + count) % count
        return routePalette[index]
    }
}