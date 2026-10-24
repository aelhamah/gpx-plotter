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

    // MARK: - Draft route (Create)
    static let draftRouteSource = "draft-route"
    static let draftRouteCasing = "draft-route-casing"
    static let draftRouteLine = "draft-route-line"
    static let draftPointsSource = "draft-points"
    static let draftPointsLayer = "draft-points"

    static let locationPointSource = "location-point"
    static let locationAccuracySource = "location-accuracy-ring"
    static let locationAccuracy = "location-accuracy"
    static let locationHalo = "location-halo"
    static let locationDot = "location-dot"
    /// The direction beam: the translucent cone on the blue dot that points the
    /// way the device faces, on the dot's own point source.
    static let locationBeam = "location-beam"
    static let locationBeamImage = "gpxnav-location-beam"

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
        static let waypointFill = UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1)

        /// Vertex and waypoint radius, interpolated between two zoom levels.
        ///
        /// A single radius is wrong in both directions on a phone. At a flat 7pt
        /// the 14-vertex demo route drew as a chain of 18pt balls that buried the
        /// line they were meant to annotate, while the same dots on a real
        /// 13,000-point track at z12 are so dense the route reads as a beaded
        /// line. Scaling with zoom fixes both: small when the whole route is in
        /// frame, legible when the user has zoomed into a section.
        ///
        /// The web app uses fixed pixel radii, which is fine against a 1,400pt
        /// desktop map and not against a 390pt phone, so this does not match it.
        static let markerRadius: (min: CGFloat, minZoom: Float, max: CGFloat, maxZoom: Float) =
            (2.5, 10, 7, 16)
        /// Extra radius for the route currently open, so "selected" reads without
        /// doubling the dot's footprint.
        static let selectedMarkerBoost: CGFloat = 1.5
        /// Stroke on the marker, interpolated over the same zoom stops as the
        /// radius.
        ///
        /// A fixed width was the other half of the too-heavy-marker problem: at a
        /// 3pt radius a 1.5pt ring covers most of the dot and the route's colour
        /// disappears under it, which is why the vertices read as dark blobs
        /// rather than as coloured points on the line.
        static let markerStroke: (min: CGFloat, max: CGFloat) = (0.5, 1.5)
        /// Softer than the web app's near-black; at phone scale a hard outline
        /// turns every vertex into a target.
        static let markerStrokeColor = UIColor(white: 0.13, alpha: 0.7)

        /// How far above its waypoint a name sits, in points. Matches the dot's
        /// own radius at a mid zoom, so the label clears the marker.
        static let waypointLabelOffset: CGFloat = 12

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

        /// The direction beam, in the same blue as the dot.
        static let locationBeamLength: CGFloat = 110
        static let locationBeamHalfAngle: CGFloat = 30
        static let locationBeamOpacity: CGFloat = 0.55
    }

    /// The direction beam's icon: a cone with its apex at the image's centre,
    /// so a `center`-anchored symbol pins the apex to the blue dot and
    /// `icon-rotate` swings the cone to the bearing — screen-sized like the dot
    /// itself (symbols do not scale with zoom), which is how Apple Maps'
    /// direction field behaves.
    ///
    /// Radially graded from `locationFill` at the apex to nearly nothing at the
    /// rim, so it reads as light cast forward rather than a wedge of plastic.
    static func beamImage() -> UIImage {
        let length = Paint.locationBeamLength
        let size = CGSize(width: length, height: length)
        let center = CGPoint(x: length / 2, y: length / 2)
        let halfAngle = Paint.locationBeamHalfAngle * .pi / 180
        // Up in UIKit's y-down coordinates is -π/2; the arc opens ±halfAngle
        // around it, clockwise from the left edge to the right one.
        let path = UIBezierPath()
        path.move(to: center)
        path.addArc(
            withCenter: center,
            radius: length / 2,
            startAngle: -.pi / 2 - halfAngle,
            endAngle: -.pi / 2 + halfAngle,
            clockwise: true
        )
        path.close()
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [
                Paint.locationFill.withAlphaComponent(0.6).cgColor,
                Paint.locationFill.withAlphaComponent(0.06).cgColor,
            ] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) else { return }
            path.addClip()
            context.cgContext.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: length / 2,
                options: []
            )
        }
    }

    /// A `circle-radius` expression that grows with the zoom level.
    ///
    /// Built from MapLibre's own `NSExpression` additions rather than a format
    /// string: `NSExpression.zoomLevelVariableExpression` is the zoom input and
    /// `init(forMLNInterpolating:curveType:parameters:stops:)` is the interpolation
    /// operator, so there is no expression grammar to hand-write here.
    static func markerRadiusExpression(boost: CGFloat = 0) -> NSExpression {
        NSExpression(
            forMLNInterpolating: NSExpression.zoomLevelVariable,
            curveType: .linear,
            parameters: nil,
            stops: NSExpression(
                forConstantValue: [
                    Paint.markerRadius.minZoom: Double(Paint.markerRadius.min + boost),
                    Paint.markerRadius.maxZoom: Double(Paint.markerRadius.max + boost),
                ]
            )
        )
    }

    /// A `circle-stroke-width` expression that keeps its weight proportional to
    /// the radius, for the reason on `Paint.markerStroke`.
    static func markerStrokeExpression() -> NSExpression {
        NSExpression(
            forMLNInterpolating: NSExpression.zoomLevelVariable,
            curveType: .linear,
            parameters: nil,
            stops: NSExpression(
                forConstantValue: [
                    Paint.markerRadius.minZoom: Double(Paint.markerStroke.min),
                    Paint.markerRadius.maxZoom: Double(Paint.markerStroke.max),
                ]
            )
        )
    }

    /// Round caps/joins, matching the web app's line settings.
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
