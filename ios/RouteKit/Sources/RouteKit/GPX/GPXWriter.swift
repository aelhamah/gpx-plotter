import Foundation

/// GPX writer, ported from `web/src/gpx.ts`.
public enum GPXWriter {
    private static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "&": result += String(decoding: [0x26, 0x61, 0x6d, 0x70, 0x3b], as: UTF8.self) // &
            case "<": result += String(decoding: [0x26, 0x6c, 0x74, 0x3b], as: UTF8.self)     // <
            case ">": result += String(decoding: [0x26, 0x67, 0x74, 0x3b], as: UTF8.self)     // >
            case "\"": result += String(decoding: [0x26, 0x71, 0x75, 0x6f, 0x74, 0x3b], as: UTF8.self) // "
            case "'": result += String(decoding: [0x26, 0x61, 0x70, 0x6f, 0x73, 0x3b], as: UTF8.self) // &apos;
            default: result.append(ch)
            }
        }
        return result
    }

    private static func formatElevation(_ meters: Double?) -> String {
        guard let meters = meters else { return "" }
        return "\n        <ele>\(String(format: "%.2f", meters))</ele>"
    }

    public static func export(routes: [Route], waypoints: [Waypoint], name: String? = nil) -> String {
        var parts: [String] = []
        parts.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        parts.append("<gpx version=\"1.1\" creator=\"GPX Plotter\" xmlns=\"http://www.topografix.com/GPX/1/1\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">")
        parts.append("  <metadata>")
        let metadataName = escape(name ?? routes.first?.name ?? "My Route")
        parts.append("    <name>\(metadataName)</name>")
        parts.append("  </metadata>")

        for route in routes {
            var trackPoints: [String] = []
            for point in route.points {
                let ele = formatElevation(point.elevation)
                trackPoints.append("      <trkpt lat=\"\(String(format: "%.7f", point.lat))\" lon=\"\(String(format: "%.7f", point.lon))\">\(ele)\n      </trkpt>")
            }
            if !trackPoints.isEmpty {
                parts.append("  <trk>")
                parts.append("    <name>\(escape(route.name.isEmpty ? "Unnamed route" : route.name))</name>")
                parts.append("    <trkseg>")
                parts.append(contentsOf: trackPoints)
                parts.append("    </trkseg>")
                parts.append("  </trk>")
            }
        }

        for wpt in waypoints {
            let ele = formatElevation(wpt.elevation)
            parts.append("  <wpt lat=\"\(String(format: "%.7f", wpt.lat))\" lon=\"\(String(format: "%.7f", wpt.lon))\">")
            parts.append("    <name>\(escape(wpt.name.isEmpty ? "Waypoint" : wpt.name))</name>\(ele)")
            parts.append("  </wpt>")
        }

        parts.append("</gpx>")
        return parts.joined(separator: "\n") + "\n"
    }
}