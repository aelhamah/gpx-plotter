import Foundation

/// Offline corridor geometry.
///
/// The plan (§8) is explicit that the download region is the route polyline
/// plus a ~1 km buffer, decided by **testing each tile centre against
/// distance-to-route** rather than by taking a bounding rectangle. A rectangle
/// over a switchbacking trail pulls in a lot of terrain nobody will look at.
public enum Corridor {
    /// Default buffer either side of the route, per the plan.
    public static let defaultBufferMeters: Double = 1_000
    /// Zoom range for satellite imagery, per the plan.
    public static let defaultImageryZoomRange = 12...16
    /// The single zoom the web app reads DEM tiles at, per the plan.
    ///
    /// Also the ceiling for the native app: MapTiler's `terrain-rgb-v2` stops at
    /// z14, and MapLibre asks a `raster-dem` source for a tile at the camera's
    /// zoom, so a corridor download wants every zoom of the basemap range *up to*
    /// this — not only z14, or relief and 3D terrain go missing at the others.
    public static let demZoomRange = 14...14

    // MARK: - Shape

    /// A closed ring approximating the buffered corridor, ready for
    /// `MLNShapeOfflineRegion`.
    ///
    /// The route is resampled finely (a quarter of the buffer) so the offset
    /// lines stay smooth through corners; each sample contributes a left and a
    /// right vertex, and the two sides are stitched into one ring. The ends are
    /// flat, which is what you want at a trailhead anyway.
    public static func shape(
        for points: [Coordinate],
        bufferMeters: Double = defaultBufferMeters,
        stepMeters: Double? = nil
    ) -> [Coordinate] {
        let step = stepMeters ?? max(bufferMeters / 4, 1)
        let samples = Profile.routeSamples(
            points.map { RoutePoint($0) },
            stepMeters: step
        ).map(\.coordinate)

        guard samples.count >= 2 else {
            // Degenerate route: a disc around the single point still gives a
            // usable (if oversized) download region.
            guard let only = samples.first else { return [] }
            return ring(around: only, radiusMeters: bufferMeters, steps: 32)
        }

        let left = offsetSide(samples, bufferMeters, sign: 1)
        let right = offsetSide(samples, bufferMeters, sign: -1)
        return left + right.reversed()
    }

    /// One side of the corridor: the route offset perpendicular by `distance`.
    ///
    /// The offset is computed in a local metric frame (metres east/north of the
    /// sample) and converted back to degrees, so a 1 km buffer stays 1 km
    /// everywhere instead of shrinking with latitude.
    private static func offsetSide(_ samples: [Coordinate], _ distance: Double, sign: Double) -> [Coordinate] {
        samples.enumerated().map { index, point in
            let previous = samples[max(0, index - 1)]
            let next = samples[min(samples.count - 1, index + 1)]

            let metersPerDegreeLat = 111_320.0
            let metersPerDegreeLon = 111_320.0 * max(cos(point.lat * .pi / 180), 0.01)

            // Tangent in metres.
            let dx = (next.lon - previous.lon) * metersPerDegreeLon
            let dy = (next.lat - previous.lat) * metersPerDegreeLat
            let length = (dx * dx + dy * dy).squareRoot()

            guard length > 0 else {
                // Degenerate: offset due north/south.
                return Coordinate(lat: point.lat + sign * distance / metersPerDegreeLat, lon: point.lon)
            }

            // Unit normal, tangent rotated 90°.
            let normalX = -dy / length
            let normalY = dx / length

            return Coordinate(
                lat: point.lat + sign * distance * normalY / metersPerDegreeLat,
                lon: point.lon + sign * distance * normalX / metersPerDegreeLon
            )
        }
    }

    private static func ring(around center: Coordinate, radiusMeters: Double, steps: Int) -> [Coordinate] {
        (0...steps).map { step in
            let bearing = Double(step) / Double(steps) * 2 * .pi
            let dLat = (radiusMeters * cos(bearing)) / 111_320
            let dLon = (radiusMeters * sin(bearing)) / (111_320 * max(cos(center.lat * .pi / 180), 0.01))
            return Coordinate(lat: center.lat + dLat, lon: center.lon + dLon)
        }
    }

    // MARK: - Tiles

    /// Tiles that the corridor passes through, across `zoomRange`.
    ///
    /// The plan (§8) says to test each tile centre against distance-to-route
    /// rather than using a rectangle. A strict centre test is wrong at low zoom:
    /// a z12 tile is ~9.8 km across but the buffer is only ~1 km, so every
    /// centre falls outside it and nothing is ever selected. The tolerance is
    /// therefore the buffer plus half the tile's diagonal — a tile is kept when
    /// any part of it could be within the corridor, which still discards the
    /// tiles at the far corners of a switchbacking route's bounding box.
    public static func tiles(
        for points: [Coordinate],
        bufferMeters: Double = defaultBufferMeters,
        zoomRange: ClosedRange<Int>
    ) -> [TileCoordinate] {
        guard !points.isEmpty, zoomRange.upperBound >= zoomRange.lowerBound else { return [] }

        let bounds = boundingBox(for: points, bufferMeters: bufferMeters)
        var result: [TileCoordinate] = []

        for zoom in zoomRange {
            // North is a *smaller* tile y than south, so the two must be
            // ordered rather than assumed.
            let westTile = TileMath.tile(lon: bounds.west, lat: bounds.north, zoom: zoom)
            let eastTile = TileMath.tile(lon: bounds.east, lat: bounds.north, zoom: zoom)
            let northTile = TileMath.tile(lon: bounds.west, lat: bounds.north, zoom: zoom)
            let southTile = TileMath.tile(lon: bounds.west, lat: bounds.south, zoom: zoom)

            let minX = min(westTile.x, eastTile.x)
            let maxX = max(westTile.x, eastTile.x)
            let minY = min(northTile.y, southTile.y)
            let maxY = max(northTile.y, southTile.y)

            for x in minX...maxX {
                for y in minY...maxY {
                    let tile = TileCoordinate(z: zoom, x: x, y: y)
                    let tolerance = bufferMeters + halfDiagonal(of: tile, latitude: bounds.north)
                    let center = TileMath.center(of: tile)
                    guard minimumDistance(from: center, to: points) <= tolerance else { continue }
                    result.append(tile)
                }
            }
        }
        return result
    }

    /// Half the tile's diagonal on the ground, at a given latitude.
    public static func halfDiagonal(of tile: TileCoordinate, latitude: Double) -> Double {
        let edge = TileMath.metersPerPixel(zoom: tile.z, midLatitude: latitude) * 256
        return edge * (sqrt(2) / 2)
    }

    /// Shortest distance from a point to the polyline, ignoring any cap.
    public static func minimumDistance(from point: Coordinate, to line: [Coordinate]) -> Double {
        guard !line.isEmpty else { return .greatestFiniteMagnitude }
        guard line.count > 1 else {
            return Haversine.meters(from: point, to: line[0])
        }

        var best = Double.greatestFiniteMagnitude
        for index in 0..<(line.count - 1) {
            let projected = projectToSegment(point, line[index], line[index + 1])
            best = min(best, Haversine.meters(from: point, to: projected))
        }
        return best
    }

    /// Bounding box around the route, expanded by the buffer.
    public static func boundingBox(for points: [Coordinate], bufferMeters: Double) -> TileBounds {
        guard let first = points.first else {
            return TileBounds(west: 0, south: 0, east: 0, north: 0)
        }
        var west = first.lon, east = first.lon, south = first.lat, north = first.lat
        for point in points.dropFirst() {
            west = min(west, point.lon)
            east = max(east, point.lon)
            south = min(south, point.lat)
            north = max(north, point.lat)
        }

        let dLat = bufferMeters / 111_320
        let dLon = bufferMeters / (111_320 * max(cos(first.lat * .pi / 180), 0.01))
        return TileBounds(
            west: west - dLon,
            south: south - dLat,
            east: east + dLon,
            north: north + dLat
        )
    }

    // MARK: - Size estimate

    /// Estimated download size for a tile list, read as vector tiles.
    ///
    /// Deliberately an estimate, and deliberately only the vector case: a style
    /// also carries a raster source and the DEM, whose tiles are up to two orders
    /// of magnitude larger, so a real estimate sums
    /// `TileSourceSize.approximateBytes(source:format:zoom:)` per source. This
    /// stays for the single-tileset case, and `CorridorTests` uses it to hold the
    /// plan's own 100–200 tile claim.
    public static func estimatedBytes(for tiles: [TileCoordinate]) -> Int {
        tiles.reduce(0) { total, tile in
            total + TileFormat.pbf.approximateBytes(atZoom: tile.z)
        }
    }
}
