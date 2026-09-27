/// A bare latitude/longitude pair. The map-free currency of RouteKit: snapping,
/// Mercator math, and the location halo all speak `Coordinate`, never a map type.
public struct Coordinate: Equatable, Hashable, Sendable, Codable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}