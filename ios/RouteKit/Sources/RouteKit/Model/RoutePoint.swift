/// One vertex of a route. `elevation` is absent when the GPX had no `<ele>` and
/// the DEM has not filled it in yet.
public struct RoutePoint: Equatable, Hashable, Sendable, Codable {
    public var lat: Double
    public var lon: Double
    public var elevation: Double?

    public init(lat: Double, lon: Double, elevation: Double? = nil) {
        self.lat = lat
        self.lon = lon
        self.elevation = elevation
    }

    public init(_ coordinate: Coordinate, elevation: Double? = nil) {
        self.init(lat: coordinate.lat, lon: coordinate.lon, elevation: elevation)
    }

    public var coordinate: Coordinate {
        get { Coordinate(lat: lat, lon: lon) }
        set {
            lat = newValue.lat
            lon = newValue.lon
        }
    }
}