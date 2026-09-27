/// Shared fallbacks for user-editable route and waypoint names.
public enum Names {
    public static func normalizeRouteName(_ raw: String, id: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Route \(id)" : trimmed
    }

    public static func normalizeWaypointName(_ raw: String, index: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Waypoint \(index + 1)" : trimmed
    }
}