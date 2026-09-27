/**
 * Which vector tiles a snap query needs. No I/O here; `snapSources` fetches.
 *
 * Snapping reads the *same* tiles the basemap draws, at the zoom the map is
 * showing, for two reasons:
 *
 *  - Zoom 13 is the worst available choice. The planet tileset generalises and
 *    drops minor paths as zoom falls, so a trail that is plainly visible on the
 *    map often has no geometry at all in a z13 tile. Measured on a recorded
 *    12.5 km hike, snapping against z13 found *no* trail at all for 39 of 83
 *    clicks taken along a trail that is mapped end to end; at z15 it found one
 *    for 75 of 83. Reading at the map's zoom also puts the snapped point on the
 *    line the user is actually looking at, instead of a coarsely generalised
 *    stand-in for it.
 *  - The zoom has a ceiling. MapTiler's `outdoor` tileset stops at z14 and the
 *    planet (`v3`) tileset at z15; anything deeper is an HTTP 400, so each
 *    source is clamped to its own maximum rather than to a shared one.
 */

/** Snapping needs a zoom where the tilesets still carry paths; z12 emits no path-like classes. */
export const SNAP_MIN_ZOOM = 14;
/** Deepest zoom either snap tileset serves (planet z15, outdoor z14). */
export const SNAP_MAX_ZOOM = 15;

/** Highest zoom each tileset actually serves. A deeper request is an HTTP 400. */
export const TILESET_MAX_ZOOM = { outdoor: 14, planet: 15 } as const;

export type TilesetId = keyof typeof TILESET_MAX_ZOOM;

const EARTH_CIRCUMFERENCE = 40075016.686;

/**
 * The zoom to snap at for a given map zoom: the map's own zoom, rounded and
 * clamped into the range the snap tilesets can serve.
 *
 * Rounded rather than floored so that panning at a fractional zoom reuses the
 * tile cache instead of refetching on every fractional step. Below
 * `SNAP_MIN_ZOOM` the basemap itself is dropping paths, so snapping anyway
 * would move a point onto something the user cannot see.
 */
export function snapZoomFor(mapZoom: number): number {
  if (!Number.isFinite(mapZoom)) return SNAP_MIN_ZOOM;
  return Math.max(SNAP_MIN_ZOOM, Math.min(SNAP_MAX_ZOOM, Math.round(mapZoom)));
}

/** The zoom a single tileset can actually serve at or below `zoom`. */
export function zoomForTileset(zoom: number, tileset: TilesetId): number {
  return Math.max(0, Math.min(zoom, TILESET_MAX_ZOOM[tileset]));
}

/**
 * Ground resolution at a latitude and zoom: meters per tile. Web Mercator
 * stretches longitude, so this is the east-west extent of a tile there.
 */
export function tileSpanMeters(lat: number, zoom: number): number {
  const clamped = Math.max(-85.05112878, Math.min(85.05112878, lat));
  return (EARTH_CIRCUMFERENCE * Math.cos((clamped * Math.PI) / 180)) / 2 ** zoom;
}

export interface TileAddress {
  x: number;
  y: number;
}

interface FractionalTile {
  x: number;
  y: number;
  /** Fractional tile coordinate, so how far the point sits from each edge is known. */
  fx: number;
  fy: number;
}

function fractionalTile(lng: number, lat: number, zoom: number): FractionalTile {
  const n = 2 ** zoom;
  const sin = Math.sin((lat * Math.PI) / 180);
  return {
    x: Math.floor(((lng + 180) / 360) * n),
    y: Math.floor((0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * n),
    fx: (((lng + 180) / 360) * n) % 1,
    fy: ((0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * n) % 1,
  };
}

/**
 * Whether a radius query centred in one tile reaches across an edge.
 *
 * Comparing the radius with the whole tile width would round every query up to
 * a full 3x3 ring, turning the common case — a point well inside a z15 tile
 * snapping at 40 m — into nine fetches per source instead of one. Measuring
 * against the actual distance to each edge keeps the common case at one tile and
 * still adds the neighbour whenever the radius really does reach it.
 */
function crosses(radius: number, offset: number, span: number): { negative: boolean; positive: boolean } {
  return {
    negative: radius > offset * span,
    positive: radius > (1 - offset) * span,
  };
}

/**
 * Every tile that can hold a point within `radiusMeters` of (lng, lat).
 *
 * A single tile clips a radius query at the tile edge, so a snap near a
 * boundary silently loses candidates. This returns the containing tile plus
 * whichever neighbours the radius actually reaches. The result is a square ring
 * rather than an exact disc: it can pull in a diagonal neighbour that the radius
 * does not quite reach, which costs one cheap tile and is far better than
 * dropping a real candidate.
 */
export function tilesNear(lng: number, lat: number, zoom: number, radiusMeters: number): TileAddress[] {
  if (!Number.isFinite(lng) || !Number.isFinite(lat)) return [];
  const span = tileSpanMeters(lat, zoom);
  if (!(span > 0)) return [];
  const radius = Math.max(0, radiusMeters);
  const centre = fractionalTile(lng, lat, zoom);
  const max = 2 ** zoom - 1;
  const dx = crosses(radius, centre.fx, span);
  const dy = crosses(radius, centre.fy, span);

  const tiles: TileAddress[] = [];
  for (let offsetY = dy.negative ? -1 : 0; offsetY <= (dy.positive ? 1 : 0); offsetY++) {
    const y = centre.y + offsetY;
    if (y < 0 || y > max) continue;
    for (let offsetX = dx.negative ? -1 : 0; offsetX <= (dx.positive ? 1 : 0); offsetX++) {
      const x = centre.x + offsetX;
      if (x < 0 || x > max) continue;
      tiles.push({ x, y });
    }
  }
  return tiles;
}

