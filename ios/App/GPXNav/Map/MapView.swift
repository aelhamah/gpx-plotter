import SwiftUI
@preconcurrency import MapLibre
import RouteKit
import CoreLocation

/// Wraps MapLibre Native's `MLNMapView` in a SwiftUI representable.
///
/// All MapLibre code is confined to this file and `MapLayers.swift`. Paint
/// values and layer ids are ported from `addDataLayers` in the web app's
/// `main.ts` so the two maps look the same.
///
/// 3D terrain is the one M2 toggle not wired here: MapLibre Native's ObjC API
/// has no terrain setter, so it has to be written into the style JSON instead.
/// See docs/ios-plan.md §6.
struct MapView: UIViewRepresentable {
    let route: Route
    /// Distance along the route the profile is scrubbed to. The map draws the
    /// covered portion as a trace, the way the web app's `profile-trace` layer
    /// does. Nil hides it.
    @Binding var scrubbedDistance: Double?
    /// Set when the style or the basemap fails to load, so the screen can say so.
    ///
    /// Without this a failure is invisible: MapLibre just leaves the view blank,
    /// and the only other symptom is that the route polyline is missing too. On
    /// a device that means a dead-looking screen with nothing to go on, which is
    /// how a loopback or key problem reads as "the map is broken".
    @Binding var loadError: String?
    /// Called every time a style finishes loading.
    ///
    /// The basemap's tile sources are only known once `StyleBuilder` has fetched
    /// and resolved the style, so the corridor estimate has to wait for that.
    /// Hearing about it beats polling: the estimate used to be computed once on
    /// appear, always before the style arrived, and never retried, so the
    /// Download button stayed disabled for the whole session.
    ///
    /// A callback rather than a binding because the coordinator writes it, and a
    /// `@Binding` cannot be written through a `let` copy of the representable.
    var onStyleLoaded: (() -> Void)?
    /// Waypoint names projected into the map view's own coordinates, for the
    /// screen-space label overlay.
    ///
    /// Drawn in SwiftUI rather than with an `MLNSymbolStyleLayer` because MapLibre
    /// Native will not resolve a feature attribute for `text` on this version:
    /// `NSExpression(forKeyPath: "label")` leaves the layer drawing nothing, while
    /// a constant string on the same layer renders fine. The labels are projected
    /// with `MLNMapView.convert(_:toPointTo:)`, which goes through the camera, so
    /// they still sit on their waypoint under pitch and 3D terrain.
    @Binding var waypointLabels: [ProjectedWaypoint]
    /// Incremented to ask the map to frame the route again. `ViewerScreen` has no
    /// handle on the `MLNMapView`, so the fit button raises this instead. Only
    /// read here, so a binding is enough.
    @Binding var fitToken: Int
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var location: LocationController

    /// Resampled profiles, kept per route so scrubbing does not resample on
    /// every gesture change. A cache, not a source of truth: the profile the
    /// stats and chart use lives in `RouteAnalysis`. It is a reference box
    /// because the layer methods are non-mutating and are also called by the
    /// coordinator, which cannot mutate the representable's own storage.
    private let profileCache = ProfileCache()
    /// The profile index the trace was last cut at, so repeated frames at the
    /// same position do no work. Reset whenever the style is replaced, because a
    /// style swap drops the trace's source and it has to be re-added.
    private let traceState = TraceState()
    /// The `fitToken` the representable last acted on, so `updateUIView` only
    /// refits when the button was actually tapped.
    private let fitState = FitState()

    init(
        route: Route,
        scrubbedDistance: Binding<Double?> = .constant(nil),
        loadError: Binding<String?> = .constant(nil),
        onStyleLoaded: (() -> Void)? = nil,
        waypointLabels: Binding<[ProjectedWaypoint]> = .constant([]),
        fitToken: Binding<Int> = .constant(0)
    ) {
        self.route = route
        self._scrubbedDistance = scrubbedDistance
        self._loadError = loadError
        self.onStyleLoaded = onStyleLoaded
        self._waypointLabels = waypointLabels
        self._fitToken = fitToken
        // Seeded, so the first `updateUIView` does not read as a fit request and
        // animate the camera over the fit the coordinator has already done.
        self.fitState.token = fitToken.wrappedValue
    }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL(for: workspace.mapStyle))
        mapView.delegate = context.coordinator
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true

        // NOTE: the style is still loading here, so sources/layers are added by
        // the coordinator in `didFinishLoading`. Adding them now would be a no-op
        // (`mapView.style` is nil) or a crash if force-unwrapped.
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let desired = styleURL(for: workspace.mapStyle)
        if mapView.styleURL != desired {
            // A style swap drops every custom source/layer; the coordinator
            // re-adds them on `didFinishLoading`.
            mapView.styleURL = desired
            context.coordinator.hasFitted = false
            traceState.index = nil
            fitState.token = nil
            return
        }
        applyEverything(to: mapView)
        refreshWaypointLabels(for: mapView)
        if fitState.token != fitToken {
            fitState.token = fitToken
            fitMapToRoute(mapView, route: route, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Style

    private func styleURL(for style: MapStyle) -> URL {
        AppConfig.styleURL(for: style, terrain3D: workspace.showTerrain3D)
    }

    // MARK: - Routes

    /// Draw every visible route, not only the one on screen, so the library
    /// overview matches the web app.
    private func applyRoutes(to mapView: MLNMapView) {
        guard let style = mapView.style else { return }
        let visible = workspace.routes.filter { ($0.visible ?? true) && $0.points.count >= 2 }
        let visibleIDs = Set(visible.map(\.id))
        let selectedID = route.id

        for candidate in visible {
            addRoute(to: style, route: candidate, selected: candidate.id == selectedID)
        }
        // Drop layers and sources for routes that were deleted or hidden.
        for layer in style.layers where layer.identifier.hasPrefix("route-") {
            guard let id = numericSuffix(of: layer.identifier), !visibleIDs.contains(id) else { continue }
            style.removeLayer(layer)
        }
        for source in style.sources where source.identifier.hasPrefix("route-") {
            guard let id = numericSuffix(of: source.identifier), !visibleIDs.contains(id) else { continue }
            style.removeSource(source)
        }
    }

    private func numericSuffix(of identifier: String) -> Int? {
        identifier.split(separator: "-").last.flatMap { Int($0) }
    }

    private func addRoute(to style: MLNStyle, route: Route, selected: Bool) {
        let sourceID = MapLayers.routeSource(route.id)
        let coordinates = route.points.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
        let line = MLNPolyline(coordinates: coordinates, count: UInt(coordinates.count))

        if style.source(withIdentifier: sourceID) == nil {
            style.addSource(MLNShapeSource(identifier: sourceID, shape: line, options: nil))
        } else if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
            existing.shape = line
        }
        guard let source = style.source(withIdentifier: sourceID) as? MLNSource else { return }

        let casingID = MapLayers.routeCasing(route.id)
        if style.layer(withIdentifier: casingID) == nil {
            let casing = MLNLineStyleLayer(identifier: casingID, source: source)
            casing.lineColor = NSExpression(forConstantValue: UIColor.white)
            casing.lineWidth = NSExpression(forConstantValue: MapLayers.Paint.routeCasingWidth)
            casing.lineOpacity = NSExpression(forConstantValue: MapLayers.Paint.routeCasingOpacity)
            MapLayers.applyRoundCaps(to: casing)
            style.addLayer(casing)
        }

        let lineID = MapLayers.routeLine(route.id)
        if style.layer(withIdentifier: lineID) == nil {
            let routeLine = MLNLineStyleLayer(identifier: lineID, source: source)
            routeLine.lineColor = NSExpression(forConstantValue: UIColor(route.color))
            routeLine.lineWidth = NSExpression(forConstantValue: MapLayers.Paint.routeLineWidth)
            MapLayers.applyRoundCaps(to: routeLine)
            style.addLayer(routeLine)
        }

        // Vertices as a circle layer rather than annotations, matching the web
        // app: annotations float above a pitched or terrain-ed map instead of
        // staying glued to the surface.
        //
        // Only for the selected route, as in the web app, and only while the
        // vertices are far enough apart to read. A switchback route has 400 of
        // them inside a few hundred metres, and drawing every one turns the line
        // into a solid blob.
        if selected, isVertexSpacingReadable(route) {
            applyRoutePoints(to: style, route: route, selected: selected)
        } else {
            removeRoutePoints(from: style, route: route)
        }
    }

    /// Whether the route's vertices are far enough apart to draw as dots.
    private func isVertexSpacingReadable(_ route: Route) -> Bool {
        guard route.points.count > 1 else { return false }
        let length = Haversine.routeLength(route.points)
        return length / Double(route.points.count) >= MapLayers.minVertexSpacingMeters
    }

    private func removeRoutePoints(from style: MLNStyle, route: Route) {
        let sourceID = MapLayers.routePoints(route.id)
        if style.layer(withIdentifier: sourceID) != nil {
            style.removeLayer(style.layer(withIdentifier: sourceID)!)
        }
        if style.source(withIdentifier: sourceID) != nil {
            style.removeSource(style.source(withIdentifier: sourceID)!)
        }
    }

    private func applyRoutePoints(to style: MLNStyle, route: Route, selected: Bool) {
        let sourceID = MapLayers.routePoints(route.id)
        // A raw GPS track can hold tens of thousands of vertices; drawing them
        // all is invisible at map scale and stalls the style.
        let thinned = downsamplePoints(route.points, maxPoints: MapLayers.maxRouteVertices)
        let coordinates = thinned.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        guard !coordinates.isEmpty else { return }
        let points = MLNPointCollection(coordinates: coordinates, count: UInt(coordinates.count))

        if style.source(withIdentifier: sourceID) == nil {
            style.addSource(MLNShapeSource(identifier: sourceID, shape: points, options: nil))
        } else if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
            existing.shape = points
        }
        guard let source = style.source(withIdentifier: sourceID) as? MLNSource else { return }

        if style.layer(withIdentifier: sourceID) == nil {
            let layer = MLNCircleStyleLayer(identifier: sourceID, source: source)
            layer.circleRadius = MapLayers.markerRadiusExpression(
                boost: selected ? MapLayers.Paint.selectedMarkerBoost : 0
            )
            layer.circleColor = NSExpression(forConstantValue: UIColor(route.color))
            layer.circleStrokeColor = NSExpression(forConstantValue: MapLayers.Paint.markerStrokeColor)
            layer.circleStrokeWidth = MapLayers.markerStrokeExpression()
            style.addLayer(layer)
        }
    }

    // MARK: - Waypoints

    private func applyWaypoints(to mapView: MLNMapView) {
        guard let style = mapView.style else { return }
        let waypoints = workspace.waypoints

        guard !waypoints.isEmpty else {
            for identifier in [MapLayers.waypointLayer] {
                if let layer = style.layer(withIdentifier: identifier) {
                    style.removeLayer(layer)
                }
            }
            if let source = style.source(withIdentifier: MapLayers.waypointSource) {
                style.removeSource(source)
            }
            return
        }

        // Features rather than a bare point collection: the label layer reads a
        // preformatted string off each feature, and an `MLNPointCollection` has
        // nowhere to put attributes.
        let features = waypoints.map { waypoint -> MLNPointFeature in
            let feature = MLNPointFeature()
            feature.coordinate = CLLocationCoordinate2D(latitude: waypoint.lat, longitude: waypoint.lon)
            // Formatted here rather than in the style expression because a MapLibre
            // expression cannot turn metres into feet, and the unit system is the
            // user's choice.
            let elevation = waypoint.elevation.map {
                Units.formatElevation($0, system: workspace.unitSystem)
            }
            feature.attributes = [
                "label": [waypoint.name, elevation].compactMap { $0 }.joined(separator: " · ")
            ]
            return feature
        }
        let collection = MLNShapeCollection(shapes: features)
        if style.source(withIdentifier: MapLayers.waypointSource) == nil {
            style.addSource(MLNShapeSource(
                identifier: MapLayers.waypointSource,
                shape: collection,
                options: nil
            ))
        } else if let existing = style.source(withIdentifier: MapLayers.waypointSource) as? MLNShapeSource {
            existing.shape = collection
        }
        guard let source = style.source(withIdentifier: MapLayers.waypointSource) as? MLNSource else { return }

        if style.layer(withIdentifier: MapLayers.waypointLayer) == nil {
            let layer = MLNCircleStyleLayer(identifier: MapLayers.waypointLayer, source: source)
            layer.circleRadius = MapLayers.markerRadiusExpression()
            layer.circleColor = NSExpression(forConstantValue: MapLayers.Paint.waypointFill)
            layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            layer.circleStrokeWidth = MapLayers.markerStrokeExpression()
            style.addLayer(layer)
        }

    }

    // MARK: - Location

    private func applyLocation(to mapView: MLNMapView) {
        guard let style = mapView.style, let fix = location.fix else { return }
        let point = CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon)

        // Two sources rather than the web app's single geometry-filtered one:
        // MapLibre Native has no shape-collection source, and splitting the
        // point from the accuracy polygon avoids needing that filter at all.
        let pointFeature = MLNPointFeature()
        pointFeature.coordinate = point
        if style.source(withIdentifier: MapLayers.locationPointSource) == nil {
            style.addSource(MLNShapeSource(
                identifier: MapLayers.locationPointSource,
                shape: pointFeature,
                options: nil
            ))
        } else if let existing = style.source(withIdentifier: MapLayers.locationPointSource) as? MLNShapeSource {
            existing.shape = pointFeature
        }
        if let source = style.source(withIdentifier: MapLayers.locationPointSource) as? MLNSource {
            if style.layer(withIdentifier: MapLayers.locationHalo) == nil {
                let halo = MLNCircleStyleLayer(identifier: MapLayers.locationHalo, source: source)
                halo.circleRadius = NSExpression(forConstantValue: MapLayers.Paint.locationHaloRadius)
                halo.circleColor = NSExpression(forConstantValue: UIColor.white)
                halo.circleOpacity = NSExpression(forConstantValue: MapLayers.Paint.locationHaloOpacity)
                style.addLayer(halo)
            }
            if style.layer(withIdentifier: MapLayers.locationDot) == nil {
                let dot = MLNCircleStyleLayer(identifier: MapLayers.locationDot, source: source)
                dot.circleRadius = NSExpression(forConstantValue: MapLayers.Paint.locationDotRadius)
                dot.circleColor = NSExpression(forConstantValue: MapLayers.Paint.locationFill)
                dot.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
                dot.circleStrokeWidth = NSExpression(forConstantValue: MapLayers.Paint.locationStrokeWidth)
                style.addLayer(dot)
            }
        }

        // The accuracy disc is a polygon so it stays glued to the ground.
        let ring = AccuracyHalo.ring(lon: fix.lon, lat: fix.lat, radiusMeters: fix.accuracyMeters)
        let ringCoordinates = ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        guard ringCoordinates.count >= 3 else { return }
        let polygon = MLNPolygonFeature(coordinates: ringCoordinates, count: UInt(ringCoordinates.count))

        if style.source(withIdentifier: MapLayers.locationAccuracySource) == nil {
            style.addSource(MLNShapeSource(
                identifier: MapLayers.locationAccuracySource,
                shape: polygon,
                options: nil
            ))
        } else if let existing = style.source(withIdentifier: MapLayers.locationAccuracySource) as? MLNShapeSource {
            existing.shape = polygon
        }
        if style.layer(withIdentifier: MapLayers.locationAccuracy) == nil,
           let source = style.source(withIdentifier: MapLayers.locationAccuracySource) as? MLNSource {
            let accuracy = MLNFillStyleLayer(identifier: MapLayers.locationAccuracy, source: source)
            accuracy.fillColor = NSExpression(forConstantValue: MapLayers.Paint.locationFill)
            accuracy.fillOpacity = NSExpression(forConstantValue: MapLayers.Paint.locationFillOpacity)
            style.addLayer(accuracy)
        }
    }

    // MARK: - Terrain overlays

    private func applyOverlays(to mapView: MLNMapView) {
        applyRelief(to: mapView)
        applySlopeRaster(to: mapView)
    }

    /// Confirms the M0 gate item "raster-dem Terrain-RGB works on Native":
    /// MapTiler's terrain-rgb-v2 is the Mapbox Terrain-RGB encoding, which is the
    /// only one `MLNRasterDEMSource` documents support for.
    private func applyRelief(to mapView: MLNMapView) {
        guard let style = mapView.style else { return }

        if workspace.showHillshade {
            if style.source(withIdentifier: MapLayers.demSource) == nil {
                style.addSource(MapLayers.makeDEMSource())
            }
            if style.layer(withIdentifier: MapLayers.reliefLayer) == nil,
               let dem = style.source(withIdentifier: MapLayers.demSource) {
                let layer = MLNHillshadeStyleLayer(identifier: MapLayers.reliefLayer, source: dem)
                layer.hillshadeExaggeration = NSExpression(
                    forConstantValue: MapLayers.Paint.hillshadeExaggeration
                )
                style.addLayer(layer)
            }
        } else {
            if style.layer(withIdentifier: MapLayers.reliefLayer) != nil {
                style.removeLayer(style.layer(withIdentifier: MapLayers.reliefLayer)!)
            }
            if style.source(withIdentifier: MapLayers.demSource) != nil {
                style.removeSource(style.source(withIdentifier: MapLayers.demSource)!)
            }
        }
    }

    private func applySlopeRaster(to mapView: MLNMapView) {
        guard let style = mapView.style else { return }

        if workspace.showSlope {
            if style.source(withIdentifier: MapLayers.slopeSource) == nil {
                style.addSource(MapLayers.makeSlopeSource())
            }
            if style.layer(withIdentifier: MapLayers.slopeLayer) == nil,
               let source = style.source(withIdentifier: MapLayers.slopeSource) {
                let layer = MLNRasterStyleLayer(identifier: MapLayers.slopeLayer, source: source)
                layer.rasterOpacity = NSExpression(forConstantValue: MapLayers.Paint.slopeOpacity)
                layer.rasterFadeDuration = NSExpression(forConstantValue: 0)
                layer.rasterResamplingMode = NSExpression(forConstantValue: "linear")
                style.addLayer(layer)
            }
        } else {
            if style.layer(withIdentifier: MapLayers.slopeLayer) != nil {
                style.removeLayer(style.layer(withIdentifier: MapLayers.slopeLayer)!)
            }
            if style.source(withIdentifier: MapLayers.slopeSource) != nil {
                style.removeSource(style.source(withIdentifier: MapLayers.slopeSource)!)
            }
        }
    }

    // MARK: - Camera

    /// Tilt the camera when 3D terrain is on, matching the web app, which does
    /// `easeTo({ pitch: 55 })` alongside `setTerrain`. Without the tilt the
    /// terrain is loaded but invisible.
    private func applyTerrainCamera(to mapView: MLNMapView) {
        let camera = mapView.camera.copy() as! MLNMapCamera
        camera.pitch = workspace.showTerrain3D ? AppConfig.terrainPitch : 0
        mapView.setCamera(camera, withDuration: 0.6, animationTimingFunction: nil)
    }

    private func fitMapToRoute(_ mapView: MLNMapView, route: Route, animated: Bool) {
        let coordinates = route.points.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
        guard let first = coordinates.first else { return }

        var sw = first, ne = first
        for coordinate in coordinates.dropFirst() {
            sw.latitude = min(sw.latitude, coordinate.latitude)
            sw.longitude = min(sw.longitude, coordinate.longitude)
            ne.latitude = max(ne.latitude, coordinate.latitude)
            ne.longitude = max(ne.longitude, coordinate.longitude)
        }

        mapView.setVisibleCoordinateBounds(
            MLNCoordinateBounds(sw: sw, ne: ne),
            edgePadding: AppConfig.fitEdgePadding,
            animated: animated
        )
    }

    // MARK: - Everything

    private func applyEverything(to mapView: MLNMapView) {
        applyRoutes(to: mapView)
        applyProfileTrace(to: mapView)
        applyWaypoints(to: mapView)
        applyLocation(to: mapView)
        applyOverlays(to: mapView)
        applyCamera(to: mapView)
    }

    // MARK: - Profile trace

    /// Draw the part of the route up to the scrubbed distance, in the web app's
    /// `TRACE_COLOR`.
    private func applyProfileTrace(to mapView: MLNMapView) {
        guard let style = mapView.style else { return }
        let profile = analysis(for: route)
        let distance = scrubbedDistance

        guard let distance, distance > 0, profile.points.count > 1 else {
            if let layer = style.layer(withIdentifier: MapLayers.profileTraceLayer) {
                style.removeLayer(layer)
            }
            if let source = style.source(withIdentifier: MapLayers.profileTraceSource) {
                style.removeSource(source)
            }
            return
        }

        // Take the samples up to the scrub point, from the same resampled
        // profile the chart and the stats use.
        let cutIndex = profile.index(nearestTo: distance)
        guard cutIndex > 0 else { return }

        // The scrub moves the trace on every frame of a drag, and the trace is
        // usually most of the profile, so re-cutting the whole polyline each
        // frame is what made the gesture stutter. MapLibre has no partial-shape
        // update, so the cut is quantised instead: at 0.05% of the route a step
        // is under a pixel wide on screen, and a drag that only re-geometries
        // every few frames is indistinguishable from a smooth one.
        let step = max(profile.totalDistance / 2000, 1)
        let quantised = (distance / step).rounded() * step
        let quantisedIndex = profile.index(nearestTo: quantised)
        guard quantisedIndex > 0, quantisedIndex != traceState.index else { return }
        traceState.index = quantisedIndex

        let coordinates = profile.points[0...quantisedIndex].map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
        let line = MLNPolyline(coordinates: coordinates, count: UInt(coordinates.count))

        if style.source(withIdentifier: MapLayers.profileTraceSource) == nil {
            style.addSource(MLNShapeSource(identifier: MapLayers.profileTraceSource, shape: line, options: nil))
        } else if let existing = style.source(withIdentifier: MapLayers.profileTraceSource) as? MLNShapeSource {
            existing.shape = line
        }
        guard style.layer(withIdentifier: MapLayers.profileTraceLayer) == nil,
              let source = style.source(withIdentifier: MapLayers.profileTraceSource) as? MLNSource
        else { return }
        let layer = MLNLineStyleLayer(identifier: MapLayers.profileTraceLayer, source: source)
        layer.lineColor = NSExpression(forConstantValue: MapLayers.Paint.traceColor)
        layer.lineWidth = NSExpression(forConstantValue: MapLayers.Paint.traceWidth)
        layer.lineOpacity = NSExpression(forConstantValue: MapLayers.Paint.traceOpacity)
        MapLayers.applyRoundCaps(to: layer)
        style.addLayer(layer)
    }

    /// The resampled profile for `route`, cached so scrubbing does not rebuild
    /// it on every gesture change.
    private func analysis(for route: Route) -> RouteProfile {
        profileCache.profile(for: route)
    }

    // MARK: - Camera

    /// Recentre on the fix and face the direction of travel, or north when the
    /// locate button is tapped a second time.
    private func applyCamera(to mapView: MLNMapView) {
        guard let fix = location.fix else { return }
        let camera = mapView.camera.copy() as! MLNMapCamera
        camera.centerCoordinate = CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon)
        if location.followsHeading, let heading = location.heading {
            camera.heading = heading
        }
        mapView.setCamera(camera, withDuration: 0.4, animationTimingFunction: nil)
    }

    /// Reference-typed memo for resampled profiles.
    private final class ProfileCache {
        private var profiles: [Int: RouteProfile] = [:]

        func profile(for route: Route) -> RouteProfile {
            if let cached = profiles[route.id] { return cached }
            let profile = RouteProfile.make(from: route.points)
            profiles[route.id] = profile
            return profile
        }
    }

    /// Reference box for the last drawn trace index, for the same reason:
    /// the representable is a struct but the gesture needs to remember where it
    /// got to.
    private final class TraceState {
        var index: Int?
    }

    /// Reference box for the last acted-on `fitToken`, for the same reason as
    /// `TraceState`: the representable is a struct, but `updateUIView` has to
    /// remember whether this update was caused by the fit button.
    private final class FitState {
        var token: Int?
    }

    /// Re-project the waypoint labels after the camera moves.
    ///
    /// Called from the coordinator's region-change callback as well as from
    /// `updateUIView`: panning does not change any SwiftUI state, so without the
    /// callback the labels would stay pinned where the last state change left
    /// them.
    func refreshWaypointLabels(for mapView: MLNMapView) {
        guard mapView.bounds.width > 0, mapView.bounds.height > 0 else {
            waypointLabels = []
            return
        }
        // Keep labels clear of the nav bar and the sheet, so they are never drawn
        // under chrome the reader cannot see past.
        var visible = mapView.bounds.insetBy(dx: -8, dy: -8)
        visible.origin.y += MapChrome.topInset
        visible.size.height -= MapChrome.topInset + MapChrome.bottomInset

        waypointLabels = workspace.waypoints.compactMap { waypoint in
            let coordinate = CLLocationCoordinate2D(latitude: waypoint.lat, longitude: waypoint.lon)
            let point = mapView.convert(coordinate, toPointTo: mapView)
            guard visible.contains(point) else { return nil }
            let elevation = waypoint.elevation.map {
                Units.formatElevation($0, system: workspace.unitSystem)
            }
            return ProjectedWaypoint(
                id: "\(waypoint.lat),\(waypoint.lon)",
                text: [waypoint.name, elevation].compactMap { $0 }.joined(separator: " · "),
                point: point
            )
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        private let parent: MapView
        var hasFitted = false

        init(_ parent: MapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            parent.loadError = nil
            parent.onStyleLoaded?()
            parent.applyEverything(to: mapView)
            if !hasFitted {
                parent.fitMapToRoute(mapView, route: parent.route, animated: false)
                hasFitted = true
            }
            // After the fit, so fitting the route does not undo the tilt.
            parent.applyTerrainCamera(to: mapView)
        }

        func mapView(_ mapView: MLNMapView, didFailToLoadWithError error: Error) {
            let nsError = error as NSError
            print("[Map] style failed to load: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
            parent.loadError = "Map failed to load: \(nsError.localizedDescription)"
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            // Panning changes no SwiftUI state, so this is the only signal that the
            // projected waypoint labels need re-laying out.
            parent.refreshWaypointLabels(for: mapView)
        }
    }
}

/// A waypoint name placed at a point in the map view's coordinates.
struct ProjectedWaypoint: Identifiable, Equatable {
    let id: String
    let text: String
    let point: CGPoint
}
