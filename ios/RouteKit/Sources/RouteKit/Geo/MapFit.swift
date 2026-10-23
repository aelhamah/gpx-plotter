/// The zoom at which a bounding box fits a padded viewport, in the style MapLibre
/// uses for `cameraForBounds`.
///
/// ## Why this is computed rather than asked for
///
/// Both MapLibre GL JS and MapLibre Native fit a bounding box with a call that
/// takes no zoom argument and gives none back. That is fine until the tileset has
/// a ceiling. MapTiler's `outdoor-v2` serves to z15 and answers **502** above it
/// rather than overzooming, so a camera sent to z17 against it draws nothing at
/// all — a flat background-coloured panel with the route polyline floating on it,
/// because that line is an overlay of ours and does not need a tile.
///
/// Reading the zoom back after the call does not fix it either: while
/// `setVisibleCoordinateBounds` is animating, `MLNMapView.zoomLevel` reports the
/// zoom it is *leaving*, so the overshoot is invisible from the turn that caused
/// it. The figure has to be known before the camera moves, which means working it
/// out here.
///
/// Pure geometry, so it is testable without a map.
import Foundation

public enum MapFit {
    /// Web Mercator clips here, and so does every style's tileset.
    static let latitudeLimit = 85.0511287798066

    /// The zoom at which `bounds` fits a viewport of `viewport` points with
    /// `padding` left empty on each edge, or nil for a degenerate box.
    ///
    /// - Parameters:
    ///   - bounds: `(west, south, east, north)` in degrees.
    ///   - viewport: the drawable size in points, already minus padding.
    ///   - padding: edges to leave empty, in points.
    public static func zoom(
        bounds: (west: Double, south: Double, east: Double, north: Double),
        viewport: (width: Double, height: Double),
        padding: (top: Double, left: Double, bottom: Double, right: Double) = (0, 0, 0, 0)
    ) -> Double? {
        let available = (
            width: viewport.width - padding.left - padding.right,
            height: viewport.height - padding.top - padding.bottom
        )
        guard available.width > 0, available.height > 0 else { return nil }

        // Normalised Mercator spans: the whole world is 1×1, so a span multiplied
        // by 512 is the number of world points it occupies at zoom 0, and by
        // 512×2^z at zoom z. The 512 is MapLibre's own unit — both Native and GL
        // JS build their transform on a 512-point tile, which is why measuring a
        // rendered map against a 256-based formula comes out two-to-one: the
        // Maroon Bells loop fitted to z14.27 rendered at 3.07 m/pt where the
        // 256-world predicts 6.18, i.e. every fit was a zoom level too deep and
        // only small routes — which pin against the tileset's ceiling with room
        // to spare — failed to show it. Setting the span equal to the space
        // available gives the fit — the viewport in the numerator, because a
        // bigger box has to be zoomed *out* to fit. The vertical span is
        // negated because `mercatorY` counts downward from the north edge, so
        // the box's north edge is always the smaller of the two.
        let spanX = abs(bounds.east - bounds.west) / 360
        let spanY = abs(mercatorY(bounds.north) - mercatorY(bounds.south))
        guard spanX > 0, spanY > 0 else { return nil }

        let zoomX = log2(available.width / (spanX * 512))
        let zoomY = log2(available.height / (spanY * 512))
        return min(zoomX, zoomY)
    }

    /// The same, clamped to a tileset's ceiling.
    ///
    /// `maxZoom` is the highest zoom worth *asking* for. Past it a tileset either
    /// stops answering or overzooms, and the two need different handling: the
    /// first is a blank map, the second a blurry one. A blank one is worse, so the
    /// clamp is a ceiling rather than a preference.
    public static func clampedZoom(
        bounds: (west: Double, south: Double, east: Double, north: Double),
        viewport: (width: Double, height: Double),
        padding: (top: Double, left: Double, bottom: Double, right: Double) = (0, 0, 0, 0),
        maxZoom: Double
    ) -> Double? {
        guard let zoom = zoom(bounds: bounds, viewport: viewport, padding: padding) else { return nil }
        return min(zoom, maxZoom)
    }

    /// The vertical position of a latitude in normalised Mercator, 0 at the north
    /// edge and 1 at the south.
    static func mercatorY(_ latitude: Double) -> Double {
        let clamped = min(max(latitude, -latitudeLimit), latitudeLimit)
        return (1 - asinh(tan(clamped * .pi / 180)) / .pi) / 2
    }
}