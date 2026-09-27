import Foundation
import RouteKit

/// Stand-in route so the map has content before GPX import lands in M2.
/// Roughly the Maroon Bells scenic loop, Colorado.
enum DemoData {
    static let route = Route(
        id: 1,
        name: "Maroon Bells Loop",
        points: [
            RoutePoint(lat: 39.0986, lon: -106.9398, elevation: 2960),
            RoutePoint(lat: 39.1010, lon: -106.9440, elevation: 3010),
            RoutePoint(lat: 39.1035, lon: -106.9482, elevation: 3120),
            RoutePoint(lat: 39.1062, lon: -106.9518, elevation: 3260),
            RoutePoint(lat: 39.1080, lon: -106.9552, elevation: 3410),
            RoutePoint(lat: 39.1068, lon: -106.9596, elevation: 3380),
            RoutePoint(lat: 39.1038, lon: -106.9620, elevation: 3290),
            RoutePoint(lat: 39.1000, lon: -106.9628, elevation: 3180),
            RoutePoint(lat: 39.0962, lon: -106.9612, elevation: 3080),
            RoutePoint(lat: 39.0938, lon: -106.9570, elevation: 3010),
            RoutePoint(lat: 39.0930, lon: -106.9518, elevation: 2975),
            RoutePoint(lat: 39.0942, lon: -106.9462, elevation: 2955),
            RoutePoint(lat: 39.0964, lon: -106.9424, elevation: 2958),
            RoutePoint(lat: 39.0986, lon: -106.9398, elevation: 2960),
        ],
        color: Colors.routeColor(forID: 1)
    )
}
