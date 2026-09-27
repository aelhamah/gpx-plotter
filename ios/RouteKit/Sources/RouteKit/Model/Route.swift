public struct Route: Equatable, Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    public var points: [RoutePoint]
    public var color: String
    /// Whether the route is shown on the map. Absent means visible (preserved for old workspaces).
    public var visible: Bool?

    public init(id: Int, name: String, points: [RoutePoint], color: String, visible: Bool? = nil) {
        self.id = id
        self.name = name
        self.points = points
        self.color = color
        self.visible = visible
    }
}