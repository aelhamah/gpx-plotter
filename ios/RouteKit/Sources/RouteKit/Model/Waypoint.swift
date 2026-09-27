public struct Waypoint: Equatable, Hashable, Sendable, Codable {
    public var lat: Double
    public var lon: Double
    public var name: String
    public var elevation: Double?

    public init(lat: Double, lon: Double, name: String, elevation: Double? = nil) {
        self.lat = lat
        self.lon = lon
        self.name = name
        self.elevation = elevation
    }

    public var coordinate: Coordinate {
        get { Coordinate(lat: lat, lon: lon) }
        set {
            lat = newValue.lat
            lon = newValue.lon
        }
    }
}