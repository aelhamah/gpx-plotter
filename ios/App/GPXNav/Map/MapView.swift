import SwiftUI
@preconcurrency import MapLibre
import RouteKit
import CoreLocation

/// Wraps MapLibre Native's `MLNMapView` in a SwiftUI representable.
///
/// M0 spike scope: MapTiler style + route polyline + `raster-dem` hillshade +
/// loopback slope raster. All MapLibre code is confined to this file.
struct MapView: UIViewRepresentable {
    let route: Route
    @EnvironmentObject private var workspace: WorkspaceStore

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
            return
        }
        applyOverlays(to: mapView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Style

    private func styleURL(for style: MapStyle) -> URL {
        AppConfig.styleURL(for: style)
    }

    // MARK: - Route layer

    private func addRouteLayer(to mapView: MLNMapView, route: Route) {
        guard let style = mapView.style, route.points.count >= 2 else { return }
        let sourceID = "route-\(route.id)"

        if style.source(withIdentifier: sourceID) == nil {
            let coordinates = route.points.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
            }
            let shape = MLNPolyline(coordinates: coordinates, count: UInt(coordinates.count))
            style.addSource(MLNShapeSource(identifier: sourceID, shape: shape, options: nil))
        }

        if style.layer(withIdentifier: "route-casing-\(route.id)") == nil {
            let casing = MLNLineStyleLayer(
                identifier: "route-casing-\(route.id)",
                source: style.source(withIdentifier: sourceID) as! MLNSource
            )
            casing.lineColor = NSExpression(forConstantValue: UIColor.white)
            casing.lineWidth = NSExpression(forConstantValue: 8)
            casing.lineOpacity = NSExpression(forConstantValue: 0.88)
            style.addLayer(casing)
        }

        if style.layer(withIdentifier: "route-line-\(route.id)") == nil {
            let line = MLNLineStyleLayer(
                identifier: "route-line-\(route.id)",
                source: style.source(withIdentifier: sourceID) as! MLNSource
            )
            line.lineColor = NSExpression(forConstantValue: UIColor(route.color))
            line.lineWidth = NSExpression(forConstantValue: 4)
            line.lineCap = NSExpression(forConstantValue: "round")
            line.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(line)
        }
    }

    private func fitMapToRoute(_ mapView: MLNMapView, route: Route) {
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
            edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40),
            animated: false
        )
    }

    // MARK: - Overlays

    private func applyOverlays(to mapView: MLNMapView) {
        applyHillshade(to: mapView)
        applySlopeRaster(to: mapView)
    }

    /// Confirms the M0 gate item "raster-dem Terrain-RGB works on Native":
    /// MapTiler's terrain-rgb-v2 is the Mapbox Terrain-RGB encoding, which is the
    /// only one `MLNRasterDEMSource` documents support for.
    private func applyHillshade(to mapView: MLNMapView) {
        guard let style = mapView.style else { return }

        if workspace.showHillshade {
            if style.source(withIdentifier: "terrain-dem") == nil {
                let dem = MLNRasterDEMSource(
                    identifier: "terrain-dem",
                    tileURLTemplates: [AppConfig.terrainTileURL],
                    options: nil
                )
                style.addSource(dem)
            }
            if style.layer(withIdentifier: "hillshade") == nil,
               let dem = style.source(withIdentifier: "terrain-dem") {
                let layer = MLNHillshadeStyleLayer(identifier: "hillshade", source: dem)
                layer.hillshadeExaggeration = NSExpression(forConstantValue: 0.5)
                style.addLayer(layer)
            }
        } else {
            if style.layer(withIdentifier: "hillshade") != nil {
                style.removeLayer(style.layer(withIdentifier: "hillshade")!)
            }
            if style.source(withIdentifier: "terrain-dem") != nil {
                style.removeSource(style.source(withIdentifier: "terrain-dem")!)
            }
        }
    }

    /// Slope rasters come from the loopback `SlopeServer`, because Native has no
    /// equivalent of the web app's `addProtocol('slope', …)`.
    private func applySlopeRaster(to mapView: MLNMapView) {
        guard let style = mapView.style else { return }

        if workspace.showSlope {
            if style.source(withIdentifier: "slope") == nil {
                let source = MLNRasterTileSource(
                    identifier: "slope",
                    tileURLTemplates: [AppConfig.slopeTileURLTemplate],
                    options: [MLNTileSourceOption.tileSize: 256]
                )
                style.addSource(source)
            }
            if style.layer(withIdentifier: "slope-layer") == nil,
               let source = style.source(withIdentifier: "slope") {
                let layer = MLNRasterStyleLayer(identifier: "slope-layer", source: source)
                layer.rasterOpacity = NSExpression(forConstantValue: 0.6)
                style.addLayer(layer)
            }
        } else {
            if style.layer(withIdentifier: "slope-layer") != nil {
                style.removeLayer(style.layer(withIdentifier: "slope-layer")!)
            }
            if style.source(withIdentifier: "slope") != nil {
                style.removeSource(style.source(withIdentifier: "slope")!)
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        private let parent: MapView
        private var hasFitRoute = false

        init(_ parent: MapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            parent.addRouteLayer(to: mapView, route: parent.route)
            parent.applyOverlays(to: mapView)
            if !hasFitRoute {
                parent.fitMapToRoute(mapView, route: parent.route)
                hasFitRoute = true
            }
        }
    }
}
