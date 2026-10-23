import SwiftUI
@preconcurrency import MapLibre
import RouteKit
import CoreLocation
import UIKit

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
    /// Whether the camera should stay on the user.
    ///
    /// Navigation sets this and the viewer does not. It is a standing follow
    /// rather than the locate button's one-shot request, because a hiker walking
    /// needs the dot under the crosshair — but it means panning is immediately
    /// undone by the next fix. A recentre affordance that suspends following is
    /// the obvious next step and is not here.
    @Binding var followsUserLocation: Bool
    /// Incremented to ask the map to frame the route again. `ViewerScreen` has no
    /// handle on the `MLNMapView`, so the fit button raises this instead. Only
    /// read here, so a binding is enough.
    @Binding var fitToken: Int
    /// The highest zoom the loaded style serves tiles for, as `StyleBuilder`
    /// resolved it from the style's own sources.
    ///
    /// Optional because the style may not have finished building when the map is
    /// first laid out; `AppConfig.fallbackMaxZoom(for:)` stands in until it does.
    /// See `StyleBuilder.maxZoom(for:)` for why getting this wrong costs the whole
    /// basemap rather than a little detail.
    let maxBasemapZoom: Double?
    /// The furniture drawn over the map by whichever screen owns it.
    ///
    /// An input rather than something read from constants, because the map does
    /// not know the navigation bar's height, the sheet's detent, or where the
    /// controls are — see `MapInsets`.
    var mapInsets: MapInsets = MapInsets()
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var location: LocationController

    init(
        route: Route,
        scrubbedDistance: Binding<Double?> = .constant(nil),
        loadError: Binding<String?> = .constant(nil),
        onStyleLoaded: (() -> Void)? = nil,
        waypointLabels: Binding<[ProjectedWaypoint]> = .constant([]),
        followsUserLocation: Binding<Bool> = .constant(false),
        fitToken: Binding<Int> = .constant(0),
        maxBasemapZoom: Double? = nil,
        mapInsets: MapInsets = MapInsets()
    ) {
        self.route = route
        self._scrubbedDistance = scrubbedDistance
        self._loadError = loadError
        self.onStyleLoaded = onStyleLoaded
        self._waypointLabels = waypointLabels
        self._followsUserLocation = followsUserLocation
        self._fitToken = fitToken
        self.maxBasemapZoom = maxBasemapZoom
        self.mapInsets = mapInsets
    }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL(for: workspace.mapStyle))
        mapView.delegate = context.coordinator
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        // The app draws its own compass, in the rail with the rest of the map
        // controls. Left on, MapLibre's second one faded in over them as soon as
        // the heading became non-zero — its own colours, its own hit area, and a
        // tap target answering `resetNorth` behind the SwiftUI buttons rather than
        // going through `LocationController`.
        // The loopback cache is the real one; see `MapLibreCache`.
        mapView.tileCacheEnabled = MapLibreCache.isEnabled

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
            // The camera is not reset: MapLibre carries it across a style
            // change, and re-fitting — which this used to do, twice over, via
            // `hasFitted = false` *and* `fitState.token = nil` — threw away
            // wherever the user had panned to every time they changed basemap
            // or toggled 3D. The new style's zoom ceiling is applied by
            // `applyZoomCeiling`, which clamps the live camera rather than
            // re-framing the route.
            //
            // `traceState.index` does reset: the swap removes the trace layer
            // with everything else, so with the index kept `applyProfileTrace`
            // would see "already drawn" and never redraw it.
            context.coordinator.traceState.index = nil
            return
        }
        // Fits before the location logic, so a recentre is the last word in the
        // update that carries one: the fits re-frame on their own schedule (the
        // token the fit button sets, the one that waits for a laid-out style),
        // and a locate request consumed *before* them came back to find the map
        // parked on the route again — the launch-argument locate never saw its
        // dot, and the same race was waiting for any locate near startup.
        //
        // Compared against the coordinator's copy, which survives updates; a box
        // stored on the struct would be recreated — and re-seeded — every time
        // SwiftUI rebuilt it, and the button would never fit anything.
        if context.coordinator.lastFitToken != fitToken {
            context.coordinator.lastFitToken = fitToken
            fitMapToRoute(mapView, route: route, animated: true)
        }
        // The style can finish loading before the view's first layout (a warm
        // loopback answers instantly), and the fit in `didFinishLoading` then
        // bails on the zero-size viewport. The first layout-driven update —
        // chrome frames, the style-loaded generation — lands here with a real
        // size, so this is the second chance. `style != nil` keeps it from
        // racing ahead of the style load itself.
        if !context.coordinator.hasFitted, mapView.style != nil {
            context.coordinator.hasFitted = fitMapToRoute(mapView, route: route, animated: false)
        }
        applyEverything(to: mapView, styleLoaded: context.coordinator.styleLoaded, coordinator: context.coordinator)
        refreshWaypointLabels(for: mapView)
        applyFollowIfNeeded(to: mapView, styleLoaded: context.coordinator.styleLoaded, coordinator: context.coordinator)
        applyHeadingIfNeeded(to: mapView, coordinator: context.coordinator)
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

        // A bare point collection: the names are drawn by the SwiftUI overlay
        // (`waypointLabels`), and the waypoint layer is circles only. A `label`
        // attribute used to ride along for a symbol layer that never worked —
        // MapLibre Native on this version would not resolve a feature attribute
        // for `text` — and nothing has read it since.
        let coordinates = waypoints.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
        let collection = MLNPointCollection(coordinates: coordinates, count: UInt(coordinates.count))
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
            // The beam goes in first: layers stack in add order, and it belongs
            // under the halo and dot so the dot sits on top of its own apex.
            if style.image(forName: MapLayers.locationBeamImage) == nil {
                style.setImage(MapLayers.beamImage(), forName: MapLayers.locationBeamImage)
            }
            if style.layer(withIdentifier: MapLayers.locationBeam) == nil {
                let beam = MLNSymbolStyleLayer(identifier: MapLayers.locationBeam, source: source)
                beam.iconImageName = NSExpression(forConstantValue: MapLayers.locationBeamImage)
                beam.iconAnchor = NSExpression(forConstantValue: "center")
                // Map-aligned in both senses: the cone lies on the ground with
                // the dot, and `icon-rotate` is a compass bearing rather than a
                // screen angle — north-up it points at north, heading-up it
                // points up the screen, the way Apple Maps' beam does.
                beam.iconRotationAlignment = NSExpression(forConstantValue: "map")
                beam.iconPitchAlignment = NSExpression(forConstantValue: "map")
                // The dot's own furniture: labels must neither push it aside
                // nor be pushed.
                beam.iconAllowsOverlap = NSExpression(forConstantValue: true)
                beam.iconIgnoresPlacement = NSExpression(forConstantValue: true)
                style.addLayer(beam)
            }
            if let beam = style.layer(withIdentifier: MapLayers.locationBeam) as? MLNSymbolStyleLayer {
                // Live only while the cycle is running on a heading the stream
                // is actually delivering (or the debug bearing stands in for it
                // on a simulator). `heading` alone survives the stream stopping
                // — a cone frozen at where you faced an hour ago is worse than
                // no cone.
                let isLive = location.followMode != .nothing
                    && location.wantsHeading
                    && location.heading != nil
                beam.iconOpacity = NSExpression(
                    forConstantValue: isLive ? MapLayers.Paint.locationBeamOpacity : 0
                )
                beam.iconRotation = NSExpression(forConstantValue: location.heading ?? 0)
            }
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
            // The DEM source is kept. The style's own JSON carries it — it is
            // what the `terrain` block reads for 3D — and removing it here tore
            // the terrain out from under a 3D view the moment hillshading went
            // off, which is the default: 3D terrain only worked with hillshade
            // also switched on. An unreferenced source fetches no tiles, so
            // keeping it costs nothing when nothing reads it.
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

    /// The zoom ceiling in force right now: what the loaded style reported, or
    /// the per-basemap backstop while it has not reported yet.
    private var zoomCeiling: Double {
        maxBasemapZoom ?? AppConfig.fallbackMaxZoom(for: workspace.mapStyle)
    }

    /// Keep MapLibre's own gesture limits inside the tile ceiling.
    ///
    /// `setVisibleCoordinateBounds` is clamped explicitly, but a pinch is
    /// MapLibre's own gesture pipeline and `maximumZoomLevel` is the only thing
    /// that reaches it. Left at its default the user can zoom straight past the
    /// last real tile and get the blank canvas this whole clamp exists to
    /// prevent — the fit was only ever the easy way in.
    private func applyZoomCeiling(to mapView: MLNMapView) {
        let ceiling = zoomCeiling
        if abs(mapView.maximumZoomLevel - ceiling) > 0.001 {
            mapView.maximumZoomLevel = ceiling
        }
        // Bring an already-flying camera down to the ceiling too.
        //
        // `maximumZoomLevel` only stops the *next* pinch. A style swap carries
        // the old camera across, and the old style may have allowed a zoom the
        // new one cannot serve — MapTiler answers 502 past a tileset's maxzoom
        // rather than overzooming, so leaving it is the blank canvas this whole
        // clamp exists to prevent. The fit already targets the ceiling, so this
        // never fights a fit in progress; it only lands the camera that arrived
        // from a style the new one has fewer tiles for.
        guard mapView.zoomLevel > ceiling + 0.001 else { return }
        let camera = mapView.camera.copy() as! MLNMapCamera
        camera.altitude = MLNAltitudeForZoomLevel(
            ceiling,
            camera.pitch,
            camera.centerCoordinate.latitude,
            mapView.bounds.size
        )
        mapView.setCamera(camera, withDuration: 0, animationTimingFunction: nil)
    }

    /// Tilt the camera when 3D terrain is on, matching the web app, which does
    /// `easeTo({ pitch: 55 })` alongside `setTerrain`. Without the tilt the
    /// terrain is loaded but invisible.
    private func applyTerrainCamera(to mapView: MLNMapView) {
        let target = workspace.showTerrain3D ? AppConfig.terrainPitch : 0
        // Only when the tilt actually changes. Called from `didFinishLoading`,
        // it used to ease unconditionally for 0.6s on every style load —
        // copying whatever camera was live at that moment. During a style swap
        // with a pan or pinch in flight that is the user's half-finished
        // camera, eased *to* itself: the map holds still for the duration and
        // then lets go somewhere the user did not put it. When the pitch is
        // already right there is nothing to move, so nothing is moved.
        guard abs(mapView.camera.pitch - target) > 0.001 else { return }
        let camera = mapView.camera.copy() as! MLNMapCamera
        camera.pitch = target
        mapView.setCamera(camera, withDuration: 0.6, animationTimingFunction: nil)
    }

    /// Frame the route, if there is a route to frame and a map to frame it in.
    ///
    /// Returns false when it did nothing, so the caller can retry later rather
    /// than latching: the loopback answers a warm style instantly and the style
    /// can finish loading before the view's first layout — a zero-size viewport
    /// yields no zoom, and MapLibre drops a camera move computed against one.
    /// Fitting once against `size == .zero` used to leave the map at its
    /// world-view default with `hasFitted` latched and nothing left to correct
    /// it.
    @discardableResult
    private func fitMapToRoute(_ mapView: MLNMapView, route: Route, animated: Bool) -> Bool {
        let bounds = Self.bounds(of: route)
        guard let bounds else { return false }
        // Before any of the padding arithmetic: an un-laid-out view is not a
        // viewport.
        guard mapView.bounds.width > 1, mapView.bounds.height > 1 else { return false }

        // `setVisibleCoordinateBounds` takes no zoom argument and, while it is
        // animating, `zoomLevel` reports the zoom it is *leaving* — so a
        // read-back clamp on this turn sees nothing wrong and the fit lands
        // wherever it wanted. Worked out here instead, before anything moves.
        //
        // That overshoot is not cosmetic: MapTiler answers 502 above a tileset's
        // maxzoom rather than overzooming, so a four-block loop fitted to a phone
        // asks for z17 against a z15 basemap and gets back no tiles at all — a
        // background-coloured panel with the route drawn on it.
        let padding = AppConfig.fitEdgePadding
        let viewport = (
            width: Double(mapView.bounds.width),
            height: Double(mapView.bounds.height)
        )
        // The sheet is up on every screen that fits, and it only reaches this
        // view as an input inset; a bottom padding smaller than the sheet frames
        // the route centred behind it, which reads as the button having done
        // nothing. The constant stays the floor for the navigation screen,
        // which draws no sheet and passes zeros.
        let paddingEdges = (
            top: Double(padding.top),
            left: Double(padding.left),
            bottom: Double(max(padding.bottom, mapInsets.bottom)),
            right: Double(padding.right)
        )
        let targetZoom = MapFit.clampedZoom(
            bounds: bounds,
            viewport: viewport,
            padding: paddingEdges,
            maxZoom: zoomCeiling
        )

        let camera = mapView.camera.copy() as! MLNMapCamera
        camera.centerCoordinate = CLLocationCoordinate2D(
            latitude: (bounds.north + bounds.south) / 2,
            longitude: (bounds.east + bounds.west) / 2
        )
        camera.heading = 0
        // `MLNMapCamera` carries an altitude and *derives* zoom from it, so a zoom
        // cannot be assigned. MapLibre exports the conversion, and it folds in the
        // viewport and the latitude that a hand-rolled `2π` formula has to guess at
        // — which is exactly the guess that was wrong here.
        if let targetZoom {
            camera.altitude = MLNAltitudeForZoomLevel(
                targetZoom,
                camera.pitch,
                camera.centerCoordinate.latitude,
                mapView.bounds.size
            )
        }
        mapView.setCamera(camera, withDuration: animated ? 0.4 : 0, animationTimingFunction: nil)
        return true
    }

    /// The geographic bounds of a route, or nil when it has no extent.
    private static func bounds(of route: Route) -> (
        west: Double, south: Double, east: Double, north: Double
    )? {
        var west = Double.infinity, south = Double.infinity
        var east = -Double.infinity, north = -Double.infinity
        for point in route.points {
            west = min(west, point.lon)
            east = max(east, point.lon)
            south = min(south, point.lat)
            north = max(north, point.lat)
        }
        guard west.isFinite, south.isFinite, east.isFinite, north.isFinite else { return nil }
        return (west, south, east, north)
    }

    // MARK: - Everything

    private func applyEverything(to mapView: MLNMapView, styleLoaded: Bool, coordinator: Coordinator) {
        applyRoutes(to: mapView)
        applyProfileTrace(to: mapView, coordinator: coordinator)
        applyWaypoints(to: mapView)
        applyLocation(to: mapView)
        applyOverlays(to: mapView)
        applyCamera(to: mapView, styleLoaded: styleLoaded, coordinator: coordinator)
        // Last, so it reads the zoom whatever the layers above settled on.
        applyZoomCeiling(to: mapView)
    }

    // MARK: - Profile trace

    /// Draw the part of the route up to the scrubbed distance, in the web app's
    /// `TRACE_COLOR`.
    private func applyProfileTrace(to mapView: MLNMapView, coordinator: Coordinator) {
        guard let style = mapView.style else { return }
        let profile = analysis(for: route, coordinator: coordinator)
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
        guard quantisedIndex > 0, quantisedIndex != coordinator.traceState.index else { return }
        coordinator.traceState.index = quantisedIndex

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
    private func analysis(for route: Route, coordinator: Coordinator) -> RouteProfile {
        coordinator.profileCache.profile(for: route)
    }

    // MARK: - Camera

    /// Recentre on the fix and face the direction of travel, or north when the
    /// locate button's cycle steps back to *my location*.
    /// - Parameter styleLoaded: whether `didFinishLoading` has run. The camera
    ///   waits for it, because the fit inside that callback re-frames the map
    ///   *after* its own `applyEverything` — a request spent there came back to
    ///   find the route fitted over the top of it.
    /// - Parameter force: move without a pending locate-button request, for the
    ///   navigation follow. The request is left unspent when forced, so a locate
    ///   tap during navigation still recentres.
    private func applyCamera(to mapView: MLNMapView, styleLoaded: Bool, coordinator: Coordinator, force: Bool = false) {
        // Only when the locate button asked. Re-centring on every fix looks fine
        // with the one-shot locate, but navigation streams fixes continuously and
        // this would then drag the camera out from under anyone panning to look at
        // something else.
        //
        // The fix is checked *before* the request is taken: a request from a cold
        // button outlives the wait for the first fix — the permission round trip,
        // `requestLocation`'s flight — and consuming it on an update where the fix
        // has not arrived yet is how "tap to show my location" could leave the map
        // parked wherever it was, with the dot off somewhere under the horizon.
        //
        // And until the style has *finished* loading (not merely begun: the
        // style object exists while its resources are still streaming). The fit
        // that lands in `didFinishLoading` re-frames the camera on its own, so
        // a request spent before it has no way to survive it.
        guard let fix = location.fix,
              styleLoaded,
              mapView.style != nil,
              force || location.consumeRecentreRequest() else { return }
        let camera = mapView.camera.copy() as! MLNMapCamera
        camera.centerCoordinate = CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon)
        applyRotation(to: camera)
        // This move has just put the camera on the current heading, so that
        // heading is not a *change* and must not be eased a second time.
        //
        // It used to be inferred instead -- `applyHeadingIfNeeded` skipped
        // whatever heading arrived first, on the assumption that something had
        // always just moved the camera. That assumption is wrong on the way into
        // navigation: the screen sets `followsHeading` without asking for a
        // recentre, so no move has happened, and the first heading off the device
        // was thrown away. The map sat north-up until the *second* update, which
        // on a stationary phone can be a long time. Saying "I consumed this
        // heading" at the point of the move is true in both cases and false in
        // neither.
        coordinator.followState.lastHeading = location.heading
        mapView.setCamera(camera, withDuration: 0.4, animationTimingFunction: nil)
    }

    /// Point the camera north, or at the direction of travel.
    ///
    /// North used to be the *absence* of an assignment: turning heading-follow off
    /// left `camera.heading` alone, and since the camera was copied forward with
    /// the bearing still on it, "tapping again snaps back to north" was a thing
    /// the docs claimed and the code did not do. The position recentred; the map
    /// stayed rotated.
    private func applyRotation(to camera: MLNMapCamera) {
        guard location.followsHeading, let heading = location.heading else {
            camera.heading = 0
            return
        }
        // Take the short way round. MapLibre eases heading linearly, so from 350
        // to 10 without this the map spins 340 degrees backwards to get there.
        var delta = heading - camera.heading
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        camera.heading = camera.heading + delta
    }

    /// Keep the bearing on the direction of travel as it changes.
    ///
    /// Driven by the heading rather than by the fix, which is the whole of the
    /// difference between heading-up and a snapshot of it: turning on the spot
    /// moves no position at all, so a gate on `lastFix != fix` never fires and the
    /// map keeps pointing where you pointed sixty seconds ago. The `lastHeading`
    /// box stops it re-easing on unrelated SwiftUI updates the same way
    /// `FollowState.lastFix` does for position.
    private func applyHeadingIfNeeded(to mapView: MLNMapView, coordinator: Coordinator) {
        guard location.followsHeading, let heading = location.heading else { return }
        guard coordinator.followState.lastHeading != heading else { return }
        coordinator.followState.lastHeading = heading

        let camera = mapView.camera.copy() as! MLNMapCamera
        applyRotation(to: camera)
        mapView.setCamera(camera, withDuration: 0.6, animationTimingFunction: nil)
    }

    /// Keep the user under the crosshair while navigating.
    ///
    /// Driven by a *changed fix* rather than by every state update: `updateUIView`
    /// runs for the unit toggle and the offline estimate too, and easing the
    /// camera on each of those would make the map twitch constantly.
    private func applyFollowIfNeeded(to mapView: MLNMapView, styleLoaded: Bool, coordinator: Coordinator) {
        let wasFollowing = coordinator.followState.isFollowing
        coordinator.followState.isFollowing = followsUserLocation
        // Turning Following back on is a request to come back to the user even
        // when the fix has not moved since, which is otherwise the one case that
        // never re-centres: a pause on a trail, or a screenshot of a simulator
        // parked at one location.
        let resumed = followsUserLocation && !wasFollowing
        // Forgetting the last bearing while heading-follow is off is what lets the
        // next turn-on rotate: `applyHeadingIfNeeded` only rotates on a *changed*
        // heading, and a heading that was current before the mode went off is
        // still current after it comes back on.
        if !location.followsHeading { coordinator.followState.lastHeading = nil }
        guard followsUserLocation, let fix = location.fix, resumed || coordinator.followState.lastFix != fix else { return }
        let firstFollow = coordinator.followState.lastFix == nil
        coordinator.followState.lastFix = fix
        // The first fix only re-centres, which leaves the camera at whatever zoom
        // the viewer left it at -- and a map that has never been moved is at the
        // style's world view, so navigation would open on a continent. RouteKit
        // already works out the zoom that frames an accuracy halo, so set that
        // and let MapLibre convert it to an altitude; afterwards the user's own
        // zoom is theirs to keep.
        if firstFollow {
            let zoom = AccuracyHalo.zoom(
                forAccuracyMeters: fix.accuracyMeters,
                latitude: fix.lat,
                maxZoom: AppConfig.navigationFollowMaxZoom
            )
            mapView.setZoomLevel(zoom, animated: false)
        }
        applyCamera(to: mapView, styleLoaded: styleLoaded, coordinator: coordinator, force: true)
    }

    /// Reference-typed memo for resampled profiles.
    fileprivate final class ProfileCache {
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
    fileprivate final class TraceState {
        var index: Int?
    }

    /// The fix the camera last followed, so a state change that did not move the
    /// user does not re-animate the map. Without it every unrelated SwiftUI
    /// update would ease the camera to the same place again.
    fileprivate final class FollowState {
        var lastFix: LocationFix?
        var isFollowing = false
        /// The bearing last rotated to, so a units toggle does not re-ease the map.
        var lastHeading: CLLocationDirection?
    }

    /// Re-project the waypoint labels after the camera moves, laying each one
    /// out so it does not cover the chrome, another label, or its own waypoint.
    ///
    /// Called from the coordinator's region-change callbacks (including
    /// `regionIsChanging`, which fires every frame of a pan or an animation) as
    /// well as from `updateUIView`: panning changes no SwiftUI state, so without
    /// them the labels would stay pinned where the last state change left them.
    ///
    /// The layout is greedy: labels are placed in waypoint order, each trying
    /// above its waypoint first and below second, the first spot that fits
    /// inside the available area and clears every obstacle and every label
    /// already placed. A label with no spot is dropped rather than piled on —
    /// which is what happens when the whole route shrinks to a corner of the
    /// screen, and is the behaviour Apple Maps has for the same reason: a name
    /// you cannot read is worse than no name.
    func refreshWaypointLabels(for mapView: MLNMapView) {
        guard mapView.bounds.width > 0, mapView.bounds.height > 0 else {
            setWaypointLabels([])
            return
        }
        let area = mapInsets.availableArea(in: mapView.bounds)
        let obstacles = mapInsets.obstacles
        var placed: [CGRect] = []
        var labels: [ProjectedWaypoint] = []

        for waypoint in workspace.waypoints {
            let coordinate = CLLocationCoordinate2D(latitude: waypoint.lat, longitude: waypoint.lon)
            let anchor = mapView.convert(coordinate, toPointTo: mapView)
            // A waypoint under the nav bar or the sheet still wants its name out
            // in the clear, so the anchor is allowed a little inside the chrome;
            // the label itself is clamped to the area proper.
            guard area.insetBy(dx: -8, dy: -8).contains(anchor) else { continue }
            let elevation = waypoint.elevation.map {
                Units.formatElevation($0, system: workspace.unitSystem)
            }
            let text = [waypoint.name, elevation].compactMap { $0 }.joined(separator: " · ")
            let size = Self.waypointLabelSize(for: text)
            // Above the waypoint reads as belonging to it; below is the
            // fallback for when something is already sitting above.
            let above = CGRect(
                x: anchor.x - size.width / 2,
                y: anchor.y - MapLayers.Paint.waypointLabelOffset - size.height,
                width: size.width, height: size.height
            )
            let below = CGRect(
                x: anchor.x - size.width / 2,
                y: anchor.y + MapLayers.Paint.waypointLabelOffset,
                width: size.width, height: size.height
            )
            guard let rect = Self.firstFit([above, below], in: area, avoiding: obstacles + placed) else {
                continue
            }
            placed.append(rect)
            labels.append(ProjectedWaypoint(
                id: "\(waypoint.lat),\(waypoint.lon)",
                text: text,
                point: CGPoint(x: rect.midX, y: rect.midY)
            ))
        }
        setWaypointLabels(labels)
    }

    /// Publishes a new label layout, skipping the assignment when nothing moved.
    ///
    /// `regionIsChanging` fires on every frame of a pan; each of those frames
    /// would otherwise invalidate the overlay even when the layout came out
    /// identical, which is most of the time at a steady zoom.
    private func setWaypointLabels(_ labels: [ProjectedWaypoint]) {
        if waypointLabels != labels {
            waypointLabels = labels
        }
    }

    /// The size `WaypointLabelOverlay` will give this label, from the same font
    /// and padding the overlay draws with.
    ///
    /// Measured here rather than reported back from SwiftUI because the layout
    /// has to know the sizes *before* drawing — a two-pass "draw then reflow"
    /// would flicker on every camera move.
    private static func waypointLabelSize(for text: String) -> CGSize {
        let base = (text as NSString).size(withAttributes: [.font: waypointLabelFont])
        return CGSize(
            width: ceil(base.width) + waypointLabelPadding.width,
            height: ceil(base.height) + waypointLabelPadding.height
        )
    }

    /// `WaypointLabelOverlay`'s font, mirrored: caption2 at the medium weight.
    private static let waypointLabelFont: UIFont = {
        let base = UIFont.preferredFont(forTextStyle: .caption2)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.medium],
        ])
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }()

    /// The overlay's capsule padding, both axes together.
    private static let waypointLabelPadding = CGSize(width: 10, height: 4)

    /// The first candidate that fits: inside `area` after clamping, and clear of
    /// every rect in `others`. Nil when none do.
    private static func firstFit(_ candidates: [CGRect], in area: CGRect, avoiding others: [CGRect]) -> CGRect? {
        for candidate in candidates {
            let rect = clamping(candidate, to: area)
            guard !others.contains(where: { $0.intersects(rect) }) else { continue }
            return rect
        }
        return nil
    }

    /// Moves `rect` wholly inside `area`, preserving its size.
    ///
    /// A label whose waypoint sits near an edge is pulled in rather than
    /// dropped; the offset from the waypoint is a rendering detail, whereas a
    /// half-clipped name is unreadable.
    private static func clamping(_ rect: CGRect, to area: CGRect) -> CGRect {
        CGRect(
            x: min(max(rect.origin.x, area.minX), max(area.minX, area.maxX - rect.width)),
            y: min(max(rect.origin.y, area.minY), max(area.minY, area.maxY - rect.height)),
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        private let parent: MapView
        var hasFitted = false

        /// Resampled profiles, kept per route so scrubbing does not resample on
        /// every gesture change. A cache, not a source of truth: the profile the
        /// stats and chart use lives in `RouteAnalysis`.
        fileprivate let profileCache = ProfileCache()
        /// The profile index the trace was last cut at, so repeated frames at
        /// the same position do no work. Reset whenever the style is replaced,
        /// because a style swap drops the trace's source and it has to be
        /// re-added.
        fileprivate let traceState = TraceState()
        /// Camera-follow state: the last fix, heading, and follow flag seen.
        ///
        /// Boxes live here rather than on the `MapView` struct for the same
        /// reason as `lastFitToken`: SwiftUI rebuilds the struct — and with it
        /// any box stored on it — on every update, so a box on the struct is
        /// fresh every time. That made `lastHeading` read nil one update after
        /// `applyCamera` set it, and `applyHeadingIfNeeded` re-eased a 0.6s
        /// rotation on every state change — each one cancelling the locate
        /// recentre mid-flight and freezing the camera a third of the way to
        /// the dot.
        fileprivate let followState = FollowState()
        /// Whether `didFinishLoading` has completed at least once. Sticky
        /// across style swaps: the swap does not re-fit (the camera carries
        /// over), so there is no window where a fit could eat a recentre.
        /// `applyCamera` waits on this rather than on `style != nil`, which
        /// goes true while the style's resources are still streaming — before
        /// the fit inside `didFinishLoading` has run.
        var styleLoaded = false
        /// The `fitToken` last acted on. Lives here, not on the struct: the
        /// coordinator is created once per map view and survives the updates
        /// that rebuild the struct, so a token stored here can actually
        /// distinguish "the button was tapped" from "SwiftUI made a new copy".
        /// Seeded from the token at creation so the first `updateUIView` does
        /// not read as a fit request and animate over the fit
        /// `didFinishLoading` is about to do.
        var lastFitToken: Int

        init(_ parent: MapView) {
            self.parent = parent
            self.lastFitToken = parent.fitToken
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            // The app draws its own compass, in the rail with the rest of the map
            // controls. Left on, MapLibre's second one faded in over them as soon
            // as the heading became non-zero — its own colours, its own hit area,
            // and a tap target answering `resetNorth` behind the SwiftUI buttons
            // rather than going through `LocationController`.
            mapView.showsCompassView = false
            parent.loadError = nil
            parent.onStyleLoaded?()
            parent.applyEverything(to: mapView, styleLoaded: styleLoaded, coordinator: self)
            if !hasFitted {
                hasFitted = parent.fitMapToRoute(mapView, route: parent.route, animated: false)
            }
            // After the fit, so fitting the route does not undo the tilt.
            parent.applyTerrainCamera(to: mapView)
            // After that too: this is the first moment the style's real ceiling is
            // known, and it is what stops the fit above having framed the route
            // against tiles that were never going to arrive.
            parent.applyZoomCeiling(to: mapView)
            // The fit moved the camera, so the labels projected before it are
            // stale. The region-change callback fires for this too, but only
            // after this method returns; refreshing here means the first frame
            // that shows the fitted route also shows the names in place.
            parent.refreshWaypointLabels(for: mapView)
            // Last: from here the load fit can no longer land behind a
            // recentre, so a pending locate request is safe to spend.
            styleLoaded = true
        }

        func mapView(_ mapView: MLNMapView, didFailToLoadWithError error: Error) {
            let nsError = error as NSError
            parent.loadError = "Map failed to load: \(nsError.localizedDescription)"
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            // Every frame of a pan, pinch, or animated camera move — not just
            // the end of it. Without this the labels swim behind the map while
            // you drag and only snap into place when you let go.
            parent.refreshWaypointLabels(for: mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            // Panning changes no SwiftUI state, so this is the only signal that the
            // projected waypoint labels need re-laying out.
            parent.refreshWaypointLabels(for: mapView)
        }
    }
}

/// A waypoint name placed at a point in the map view's coordinates.
///
/// `point` is the label's final centre: clamped to the available area and
/// checked against the chrome and the other labels by
/// `MapView.refreshWaypointLabels`, so the overlay draws it wherever it is.
struct ProjectedWaypoint: Identifiable, Equatable {
    let id: String
    let text: String
    let point: CGPoint
}

/// The screen furniture drawn over the map, in map-view points.
///
/// Supplied by the screen rather than read from constants here, because none of
/// it is knowable from inside the map: the navigation bar's height depends on the
/// display, the sheet's height depends on a detent the screen owns, and the
/// controls move with it. Getting this wrong is invisible — the map still draws,
/// the labels just end up underneath the furniture.
struct MapInsets: Equatable {
    /// Below the navigation bar.
    var top: CGFloat = 0
    /// Above the sheet's top edge — which includes the tab bar.
    var bottom: CGFloat = 0
    /// Rectangles the label layout must avoid entirely, in map-view points.
    ///
    /// Separate from the edge insets on purpose: an edge inset *moves the frame*
    /// and so throws away every label near that edge, whereas an obstacle only
    /// costs the labels that would have landed on it. Empty by default, so the
    /// navigation screen — which draws no controls — pays nothing for it.
    var obstacles: [CGRect] = []

    /// `bounds` less the edge insets: the area a label may occupy at all.
    ///
    /// Named for what it answers rather than `inset(by:)`, which `CGRect` already
    /// claims with a different meaning and a different argument type.
    func availableArea(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: bounds.minY + top,
            width: bounds.width,
            height: max(0, bounds.height - top - bottom)
        )
    }
}
