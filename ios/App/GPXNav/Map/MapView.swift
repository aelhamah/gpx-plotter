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
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var location: LocationController

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
            return
        }
        applyEverything(to: mapView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Style

    private func styleURL(for style: MapStyle) -> URL {
        AppConfig.styleURL(for: style)
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
        applyRoutePoints(to: style, route: route, selected: selected)
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
            layer.circleRadius = NSExpression(
                forConstantValue: selected
                    ? MapLayers.Paint.routePointSelectedRadius
                    : MapLayers.Paint.routePointRadius
            )
            layer.circleColor = NSExpression(forConstantValue: UIColor(route.color))
            layer.circleStrokeColor = NSExpression(
                forConstantValue: selected ? MapLayers.Paint.routePointSelectedStroke : UIColor.white
            )
            layer.circleStrokeWidth = NSExpression(forConstantValue: MapLayers.Paint.routePointStrokeWidth)
            style.addLayer(layer)
        }
    }

    // MARK: - Waypoints

    private func applyWaypoints(to mapView: MLNMapView) {
        guard let style = mapView.style else { return }
        let waypoints = workspace.waypoints

        guard !waypoints.isEmpty else {
            if let layer = style.layer(withIdentifier: MapLayers.waypointLayer) {
                style.removeLayer(layer)
            }
            if let source = style.source(withIdentifier: MapLayers.waypointSource) {
                style.removeSource(source)
            }
            return
        }

        let coordinates = waypoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let points = MLNPointCollection(coordinates: coordinates, count: UInt(coordinates.count))
        if style.source(withIdentifier: MapLayers.waypointSource) == nil {
            style.addSource(MLNShapeSource(identifier: MapLayers.waypointSource, shape: points, options: nil))
        } else if let existing = style.source(withIdentifier: MapLayers.waypointSource) as? MLNShapeSource {
            existing.shape = points
        }
        guard style.layer(withIdentifier: MapLayers.waypointLayer) == nil,
              let source = style.source(withIdentifier: MapLayers.waypointSource) as? MLNSource
        else { return }

        let layer = MLNCircleStyleLayer(identifier: MapLayers.waypointLayer, source: source)
        layer.circleRadius = NSExpression(forConstantValue: MapLayers.Paint.waypointRadius)
        layer.circleColor = NSExpression(forConstantValue: MapLayers.Paint.waypointFill)
        layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
        layer.circleStrokeWidth = NSExpression(forConstantValue: MapLayers.Paint.routePointStrokeWidth)
        style.addLayer(layer)
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
        applyWaypoints(to: mapView)
        applyLocation(to: mapView)
        applyOverlays(to: mapView)
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
            parent.applyEverything(to: mapView)
            if !hasFitted {
                parent.fitMapToRoute(mapView, route: parent.route, animated: false)
                hasFitted = true
            }
        }
    }
}
