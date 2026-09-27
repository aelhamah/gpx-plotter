import Foundation

public struct ParsedGPX: Equatable, Sendable {
    public var routes: [Route]
    public var waypoints: [Waypoint]
    public var metadataName: String?

    public init(routes: [Route], waypoints: [Waypoint], metadataName: String? = nil) {
        self.routes = routes
        self.waypoints = waypoints
        self.metadataName = metadataName
    }
}

public enum GPXError: Error, LocalizedError {
    case invalidXML(String)
    case noData

    public var errorDescription: String? {
        switch self {
        case .invalidXML(let message):
            return "The selected file is not valid XML/GPX: \(message)"
        case .noData:
            return "No track, route, or waypoint data was found in this GPX file."
        }
    }
}

/// Streaming GPX parser, ported from `web/src/gpx.ts`.
///
/// Uses `XMLParser` rather than the web app's `DOMParser`, so a large track
/// never has to be materialised as a document tree. Namespaces are ignored
/// (`shouldProcessNamespaces = false`) to match `getElementsByTagNameNS('*', …)`.
public final class GPXParser: NSObject, XMLParserDelegate {
    /// Element whose text is currently being accumulated.
    private enum TextTarget {
        case name
        case elevation
    }

    private var routes: [Route] = []
    private var waypoints: [Waypoint] = []
    private var metadataName: String?

    private var textTarget: TextTarget?
    private var textBuffer = ""

    private var currentRouteName: String?
    private var currentRoutePoints: [RoutePoint] = []
    private var currentSegmentPoints: [RoutePoint] = []
    private var currentPoint: RoutePoint?
    private var currentWaypoint: Waypoint?
    private var waypointIndex = 0

    private var inMetadata = false
    private var inTrack = false
    private var inRoute = false
    private var inSegment = false

    public override init() {
        super.init()
    }

    public func parse(_ xmlText: String) throws -> ParsedGPX {
        guard let data = xmlText.data(using: .utf8) else {
            throw GPXError.invalidXML("could not encode input as UTF-8")
        }
        reset()

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw GPXError.invalidXML(parser.parserError?.localizedDescription ?? "unknown parsing error")
        }

        guard !routes.allSatisfy(\.points.isEmpty) || !waypoints.isEmpty else {
            throw GPXError.noData
        }
        return ParsedGPX(
            routes: routes.filter { !$0.points.isEmpty },
            waypoints: waypoints,
            metadataName: metadataName
        )
    }

    private func reset() {
        routes = []
        waypoints = []
        metadataName = nil
        textTarget = nil
        textBuffer = ""
        currentRouteName = nil
        currentRoutePoints = []
        currentSegmentPoints = []
        currentPoint = nil
        currentWaypoint = nil
        waypointIndex = 0
        inMetadata = false
        inTrack = false
        inRoute = false
        inSegment = false
    }

    // MARK: - XMLParserDelegate

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "metadata":
            inMetadata = true
        case "trk":
            inTrack = true
            currentRouteName = nil
            currentRoutePoints = []
        case "rte":
            inRoute = true
            currentRouteName = nil
            currentRoutePoints = []
        case "trkseg":
            inSegment = true
            currentSegmentPoints = []
        case "trkpt", "rtept":
            if let point = Self.point(from: attributeDict) {
                currentPoint = point
                if inSegment {
                    currentSegmentPoints.append(point)
                } else {
                    currentRoutePoints.append(point)
                }
            }
        case "wpt":
            if let point = Self.point(from: attributeDict) {
                currentWaypoint = Waypoint(
                    lat: point.lat,
                    lon: point.lon,
                    name: "",
                    elevation: point.elevation
                )
            }
        case "name":
            beginText(.name)
        case "ele":
            beginText(.elevation)
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        // XMLParser may split one text run across several callbacks (notably at
        // entity boundaries), so accumulate and commit when the element closes.
        guard textTarget != nil else { return }
        textBuffer += string
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "name":
            endText()
        case "ele":
            endText()
        case "metadata":
            inMetadata = false
        case "trkseg":
            inSegment = false
            currentRoutePoints.append(contentsOf: currentSegmentPoints)
        case "trk", "rte":
            let isTrack = elementName == "trk"
            inTrack = false
            inRoute = false
            let fallback = routes.isEmpty
                ? "Imported Route"
                : (isTrack ? "Track \(routes.count + 1)" : "Route \(routes.count + 1)")
            let name = currentRouteName ?? fallback
            routes.append(
                Route(id: routes.count + 1, name: name, points: currentRoutePoints, color: "")
            )
            currentRouteName = nil
            currentRoutePoints = []
        case "trkpt", "rtept":
            currentPoint = nil
        case "wpt":
            if var waypoint = currentWaypoint {
                waypoint.name = Names.normalizeWaypointName(waypoint.name, index: waypointIndex)
                waypoints.append(waypoint)
                waypointIndex += 1
                currentWaypoint = nil
            }
        default:
            break
        }
    }

    // MARK: - Text accumulation

    private func beginText(_ target: TextTarget) {
        textTarget = target
        textBuffer = ""
    }

    private func endText() {
        defer {
            textTarget = nil
            textBuffer = ""
        }
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        switch textTarget {
        case .name:
            if inMetadata {
                metadataName = text
            } else if inTrack || inRoute {
                currentRouteName = text
            } else if currentWaypoint != nil {
                currentWaypoint?.name = text
            }
        case .elevation:
            guard let elevation = Double(text), elevation.isFinite else { return }
            if var point = currentPoint, point.elevation == nil {
                point.elevation = elevation
                Self.replace(point, in: &currentSegmentPoints)
                Self.replace(point, in: &currentRoutePoints)
                currentPoint = point
            } else if var waypoint = currentWaypoint, waypoint.elevation == nil {
                waypoint.elevation = elevation
                currentWaypoint = waypoint
            }
        case nil:
            break
        }
    }

    private static func replace(_ point: RoutePoint, in points: inout [RoutePoint]) {
        guard let index = points.indices.last(where: {
            points[$0].lat == point.lat && points[$0].lon == point.lon && points[$0].elevation == nil
        }) else { return }
        points[index] = point
    }

    private static func point(from attributes: [String: String]) -> RoutePoint? {
        guard let latText = attributes["lat"], let lonText = attributes["lon"],
              let lat = Double(latText), let lon = Double(lonText),
              lat.isFinite, lon.isFinite
        else { return nil }

        var elevation: Double?
        if let eleText = attributes["ele"], let ele = Double(eleText), ele.isFinite {
            elevation = ele
        }
        return RoutePoint(lat: lat, lon: lon, elevation: elevation)
    }
}

/// Parse a GPX document. Throws `GPXError` for malformed or empty files.
public func parseGPX(_ xmlText: String) throws -> ParsedGPX {
    try GPXParser().parse(xmlText)
}
