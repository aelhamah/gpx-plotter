/**
 * Which vector tiles to read for a snap, and at what zoom.
 *
 * Two things the snap path needs to know before it can fetch anything:
 *
 *  - **Zoom.** Zoom 13 is coarse enough to be cached cheaply but its geometry
 *    is heavily generalized, so a snapped point sits visibly off the trail the
 *    basemap draws once the user zooms in. Following the map zoom keeps the
 *    candidates as detailed as what is on screen.
 *  - **Coverage.** A snap threshold is a *radius*, but a tile is a fixed
 *    square. Reading only the tile that contains the click means anything
 *    within snapping distance of a tile edge is unreachable, so the working
 *    area stops at an invisible line and the snapping region looks shifted.
 *    These helpers return every tile the radius can reach into.
 *
 * Pure math (no I/O, no DOM), so it is unit-testable.
 */

import { lngLatToTile } from './dem';

/** Coarsest zoom read for snapping; also the fallback when a detail tile is empty. */
export const SNAP_BASE_ZOOM = 13;
/** Finest zoom read for snapping. Above this the tilesets add nothing useful. */
export const SNAP_MAX_ZOOM = 16;

/** Web Mercator equator circumference, in meters. */
const EQUATOR_METERS = 40075016.686;

/** The app's radii top out at 250 m, which never reaches past one ring of tiles. */
const MAX_RING = 1;

export interface TileCoord {
  x: number;
  y: number;
}

/**
 * Zoom to read snap candidates at: track the map, but never coarser than
 * {@link SNAP_BASE_ZOOM} (too generalized to snap against) nor finer than
 * {@link SNAP_MAX_ZOOM}. Rounded so panning at a fractional zoom reuses the
 * cache instead of refetching.
 */
export function snapZoomFor(mapZoom: number, maxZoom = SNAP_MAX_ZOOM): number {
  if (!Number.isFinite(mapZoom)) return SNAP_BASE_ZOOM;
  return Math.max(SNAP_BASE_ZOOM, Math.min(maxZoom, Math.round(mapZoom)));
}

/**
 * Ground meters per tile at a latitude. Web Mercator is conformal, so a tile is
 * square in meters as well as in pixels. Clamped away from zero so the poles do
 * not produce a division by zero.
 */
export function tileSpanMeters(lat: number, zoom: number): number {
  const scale = Math.max(Math.cos((lat * Math.PI) / 180), 1e-6);
  return (EQUATOR_METERS * scale) / 2 ** zoom;
}

/**
 * Every tile that can hold geometry within `radiusMeters` of the point,
 * including the tile containing it. Indices are clamped to the zoom's valid
 * range, so the result is always a plain `x`/`y` tile address.
 *
 * The radius is treated as a square around the point, which can pull in a
 * diagonal neighbour that is slightly further than `radiusMeters` away. That is
 * deliberate: over-fetching is harmless (callers still apply the real radius
 * when picking the nearest candidate), whereas under-fetching is the bug.
 */
export function snapTilesFor(lng: number, lat: number, zoom: number, radiusMeters: number): TileCoord[] {
  const { x, y } = lngLatToTile(lng, lat, zoom);
  // Past the Mercator limit (|lat| >= ~85.05) the tile index is not finite and
  // there is no tile to read. Bailing out also keeps the ranges below finite.
  if (!Number.isFinite(x) || !Number.isFinite(y)) return [];
  const maxTile = 2 ** zoom - 1;
  const span = tileSpanMeters(lat, zoom);
  const reach = Math.abs(radiusMeters) / span;
  if (!Number.isFinite(reach)) return [];

  // A tile at index i has its nearest edge `i - x` (or `x - (i + 1)`) tile units
  // from the point, so the tiles within `reach` are exactly the indices in that
  // interval — one ring wider than the containing tile whenever the point sits
  // closer to an edge than the radius. Clamped to one ring either way, which the
  // app's radii never exceed but keeps a large radius from fanning out.
  const ring = (value: number) => [
    Math.max(Math.floor(value) - MAX_RING, Math.ceil(value - reach) - 1),
    Math.min(Math.floor(value) + MAX_RING, Math.floor(value + reach)),
  ];
  const [minX, maxX] = ring(x);
  const [minY, maxY] = ring(y);

  const tiles: TileCoord[] = [];
  for (let ty = minY; ty <= maxY; ty++) {
    const cy = Math.max(0, Math.min(maxTile, ty));
    for (let tx = minX; tx <= maxX; tx++) {
      const cx = Math.max(0, Math.min(maxTile, tx));
      // Clamping collapses indices at the world's edge, so skip the repeats.
      const last = tiles[tiles.length - 1];
      if (last && last.x === cx && last.y === cy) continue;
      tiles.push({ x: cx, y: cy });
    }
  }
  return tiles;
}
