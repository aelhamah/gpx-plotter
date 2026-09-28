import UIKit
import MapLibre
import RouteKit

/// Map layer identifiers and paint, ported from `addDataLayers` in the web app's
/// `main.ts` so the native map matches it.
///
/// The route and waypoint markers are style layers rather than annotations for
/// the reason the web app moved them off DOM markers: annotations float above
/// pitched and terrain-ed maps instead of staying glued to the surface.
enum MapLayers {
    // MARK: - Route

    static func routeSource(_ id: Int) -> String { "route-\(id)" }
    static func routeCasing(_ id: Int) -> String { "route-casing-\(id)" }
    static func routeLine(_ id: Int) -> String { "route-line-\(id)" }
    static func routePoints(_ id: Int) -> String { "route-points-\(id)" }

    /// The covered portion of the route while the profile is scrubbed.
    static let profileTraceSource = "profile-trace"
    static let profileTraceLayer = "profile-trace"

    // MARK: - Waypoints

    static let waypointSource = "waypoints"
    static let waypointLayer = "waypoint-points"

    // MARK: - Location

    static let locationPointSource = "location-point"
    static let locationAccuracySource = "location-accuracy-ring"
    static let locationAccuracy = "location-accuracy"
    static let locationHalo = "location-halo"
    static let locationDot = "location-dot"

    // MARK: - Terrain

    static let demSource = AppConfig.demSource
    static let slopeSource = "slope"
    static let reliefLayer = "relief"
    static let slopeLayer = "slope-shading"

    /// Highest zoom MapTiler's terrain-rgb-v2 serves, matching `DEM_MAX_ZOOM`.
    static let demMaxZoom = 14

    /// Cap on drawn route vertices. A raw GPS track holds tens of thousands and
    /// they are invisible at map scale.
    static let maxRouteVertices = 400

    /// Below this much space between vertices, drawing them turns the route into
    /// a solid blob, so they are dropped and only the line is drawn.
    static let minVertexSpacingMeters: Double = 20

    // MARK: - Paint

    enum Paint {
        static let routeCasingWidth: CGFloat = 8
        static let routeCasingOpacity: CGFloat = 0.88
        static let routeLineWidth: CGFloat = 4
        static let routePointRadius: CGFloat = 7
        static let routePointSelectedRadius: CGFloat = 9
        static let routePointStrokeWidth: CGFloat = 2
        static let routePointSelectedStroke = UIColor(red: 0.067, green: 0.067, blue: 0.067, alpha: 1)

        static let waypointRadius: CGFloat = 7
        static let waypointFill = UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1)

        static let hillshadeShadow = UIColor(red: 0.200, green: 0.255, blue: 0.333, alpha: 1)
        static let hillshadeHighlight = UIColor.white
        static let hillshadeAccent = UIColor(red: 0.392, green: 0.455, blue: 0.545, alpha: 1)
        static let hillshadeExaggeration: CGFloat = 0.5

        static let slopeOpacity: CGFloat = 0.9
        static let tileSize: Int = 512

        /// The web app's `TRACE_COLOR`, for the profile trace.
        static let traceColor = UIColor(red: 0.055, green: 0.647, blue: 0.914, alpha: 1)
        static let traceWidth: CGFloat = 7
        static let traceOpacity: CGFloat = 0.85

        static let locationFill = UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1)
        static let locationFillOpacity: CGFloat = 0.14
        static let locationHaloRadius: CGFloat = 8
        static let locationHaloOpacity: CGFloat = 0.85
        static let locationDotRadius: CGFloat = 5.5
        static let locationStrokeWidth: CGFloat = 1.5
    }

    /// Round/butt/join settings the web app applies to every line layer.
    static func applyRoundCaps(to layer: MLNLineStyleLayer) {
        layer.lineCap = NSExpression(forConstantValue: "round")
        layer.lineJoin = NSExpression(forConstantValue: "round")
    }

    /// The DEM source both the relief layer and 3D terrain read from.
    ///
    /// It normally does not have to be added: `StyleBuilder` puts a `terrain`
    /// source in the style so 3D terrain has a block to point at, and it shares
    /// this id. The keyless demo basemap loads MapLibre's style untouched, so
    /// there the layer has to bring its own.
    static func makeDEMSource() -> MLNRasterDEMSource {
        MLNRasterDEMSource(
            identifier: demSource,
            tileURLTemplates: [AppConfig.demTileURLTemplate],
            options: [
                MLNTileSourceOption.tileSize: Paint.tileSize,
                MLNTileSourceOption.maximumZoomLevel: demMaxZoom
            ]
        )
    }

    /// Slope rasters come from the loopback `SlopeServer`, because Native has no
    /// equivalent of the web app's `addProtocol('slope', …)`.
    static func makeSlopeSource() -> MLNRasterTileSource {
        MLNRasterTileSource(
            identifier: slopeSource,
            tileURLTemplates: [AppConfig.slopeTileURLTemplate],
            options: [
                MLNTileSourceOption.tileSize: Paint.tileSize,
                MLNTileSourceOption.maximumZoomLevel: demMaxZoom
            ]
        )
    }
}
