/**
 * Fetches snap candidates from MapTiler's vector tilesets:
 *  - `outdoor`    → "trail" layer (marked hiking/biking routes) and
 *  - planet (v3)  → "transportation" layer, filtered to path-like classes,
 *                   because the `trail` layer only carries trails that belong
 *                   to a route relation (many ordinary paths are missing there).
 *  - planet (v3)  → "mountain_peak" layer for snapping waypoints onto peaks.
 *
 * These are the same tilesets the map style already references, read at the zoom
 * the map is showing and clamped to each tileset's own maximum zoom (see
 * `snapTiles`). A radius query spans every tile the radius can reach into, so a
 * snap near a tile boundary does not lose candidates. Decoded tiles are cached
 * per source/z/x/y; failed reads are dropped from the cache so one bad response
 * does not disable snapping for that tile for the rest of the session.
 */

import { OUTDOOR_TILE_URL, PLANET_TILE_URL } from './config';
import { decodeTile, layerByName, tilePointToLngLat, type MVTLayer } from './mvt';
import { PEAK_SNAP_METERS, TRAIL_SNAP_METERS, type SnapPoint } from './snap';
import {
  SNAP_MIN_ZOOM,
  tilesNear,
  zoomForTileset,
  type TileAddress,
  type TilesetId,
} from './snapTiles';
import { reportServiceFailure } from './serviceStatus';

const CACHE_CAP = 256;

/** `transportation` classes that count as a walkable/rideable trail. */
const TRAIL_CLASSES = new Set([
  'path',
  'footway',
  'steps',
  'track',
  'cycleway',
  'bridleway',
  'pedestrian',
  'corridor',
]);

export interface PeakInfo {
  name?: string;
  elevation?: number;
  center: SnapPoint;
}

interface DecodedTile {
  layers: MVTLayer[];
  z: number;
  x: number;
  y: number;
}

const tileCache = new Map<string, Promise<DecodedTile>>();

/**
 * Decode one tile, rejecting if it cannot be read. A failed read is *not* left
 * in the cache: caching the rejection is what used to make a single 429 or 400
 * silently disable snapping over an area until the page was reloaded.
 */
async function readTile(tileset: TilesetId, z: number, tile: TileAddress): Promise<DecodedTile> {
  const urlTemplate = tileset === 'outdoor' ? OUTDOOR_TILE_URL : PLANET_TILE_URL;
  const key = `${tileset}/${z}/${tile.x}/${tile.y}`;
  const cached = tileCache.get(key);
  if (cached) return cached;
  if (tileCache.size >= CACHE_CAP) {
    const oldest = tileCache.keys().next().value;
    if (oldest !== undefined) tileCache.delete(oldest);
  }
  const job = (async (): Promise<DecodedTile> => {
    const url = urlTemplate.replace('{z}', String(z)).replace('{x}', String(tile.x)).replace('{y}', String(tile.y));
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Snap tile ${key} failed with ${response.status}`);
    return { layers: decodeTile(new Uint8Array(await response.arrayBuffer())), z, x: tile.x, y: tile.y };
  })();
  tileCache.set(key, job);
  try {
    return await job;
  } catch (error) {
    if (tileCache.get(key) === job) tileCache.delete(key);
    throw error;
  }
}

interface TileRead {
  decoded: DecodedTile[];
  failures: string[];
  attempted: number;
}

/**
 * Read every tile of one tileset whose area can hold a candidate within
 * `radiusMeters`, keeping the ones that succeeded so a single unreachable tile
 * costs its own candidates rather than the whole snap.
 *
 * The tile ring is worked out per tileset, at the zoom that tileset is actually
 * being asked for: the outdoor tileset caps out one zoom short of the planet
 * one, and its tile indices are on a different grid at that zoom.
 */
async function readTiles(
  tileset: TilesetId,
  zoom: number,
  lng: number,
  lat: number,
  radiusMeters: number,
): Promise<TileRead> {
  const z = zoomForTileset(zoom, tileset);
  const tiles = tilesNear(lng, lat, z, radiusMeters);
  if (tiles.length === 0) return { decoded: [], failures: [], attempted: 0 };
  const results = await Promise.allSettled(tiles.map((tile) => readTile(tileset, z, tile)));
  const decoded: DecodedTile[] = [];
  const failures: string[] = [];
  for (const result of results) {
    if (result.status === 'fulfilled') decoded.push(result.value);
    else failures.push(String(result.reason?.message ?? result.reason));
  }
  return { decoded, failures, attempted: tiles.length };
}

function tilePointLine(part: [number, number][], decoded: DecodedTile, extent: number): SnapPoint[] {
  return part.map(([px, py]) => {
    const { lng, lat } = tilePointToLngLat(decoded.z, decoded.x, decoded.y, extent, px, py);
    return { lon: lng, lat };
  });
}

function linesFromLayer(decoded: DecodedTile, layerName: string, keep?: (props: Record<string, unknown>) => boolean): SnapPoint[][] {
  const layer = layerByName(decoded.layers, layerName);
  if (!layer) return [];
  const lines: SnapPoint[][] = [];
  for (const feature of layer.features) {
    if (feature.type !== 2) continue;
    if (keep && !keep(feature.props)) continue;
    for (const part of feature.parts) {
      if (part.length === 0) continue;
      lines.push(tilePointLine(part, decoded, layer.extent));
    }
  }
  return lines;
}

/**
 * Trail polylines within `radiusMeters` of a point, combining the marked
 * `trail` layer with path-like `transportation` lines. `zoom` is the map's
 * current zoom; it is clamped to what the tilesets serve. Returns [] when every
 * source fails.
 */
export async function trailsNearPoint(
  lng: number,
  lat: number,
  zoom: number = SNAP_MIN_ZOOM,
  radiusMeters: number = TRAIL_SNAP_METERS,
): Promise<SnapPoint[][]> {
  const [marked, paths] = await Promise.all([
    readTiles('outdoor', zoom, lng, lat, radiusMeters),
    readTiles('planet', zoom, lng, lat, radiusMeters),
  ]);

  const markedLines = marked.decoded.flatMap((tile) => linesFromLayer(tile, 'trail'));
  const pathLines = paths.decoded.flatMap((tile) =>
    linesFromLayer(tile, 'transportation', (props) => typeof props.class === 'string' && TRAIL_CLASSES.has(props.class)),
  );

  // Snapping has always failed silently, which makes an outage and "there is
  // genuinely no trail here" look identical to the user. Only complain when
  // every tile of both sources failed: a partial read is a normal, recoverable
  // edge, and the basemap is still drawing from these same tilesets.
  const failures = [...marked.failures, ...paths.failures];
  const attempted = marked.attempted + paths.attempted;
  if (attempted > 0 && failures.length === attempted) reportServiceFailure('snap', failures.join('; '));

  return [...markedLines, ...pathLines];
}

/** Peaks within `radiusMeters` of a point, or [] on failure. */
export async function peaksNearPoint(
  lng: number,
  lat: number,
  zoom: number = SNAP_MIN_ZOOM,
  radiusMeters: number = PEAK_SNAP_METERS,
): Promise<PeakInfo[]> {
  const { decoded, failures, attempted } = await readTiles('planet', zoom, lng, lat, radiusMeters);
  if (attempted > 0 && decoded.length === 0) {
    reportServiceFailure('snap', failures.join('; '));
    return [];
  }
  const peaks: PeakInfo[] = [];
  for (const tile of decoded) {
    const layer = layerByName(tile.layers, 'mountain_peak');
    if (!layer) continue;
    for (const feature of layer.features) {
      if (feature.type !== 1) continue;
      for (const part of feature.parts) {
        const [px, py] = part[0] ?? [0, 0];
        const { lng, lat } = tilePointToLngLat(tile.z, tile.x, tile.y, layer.extent, px, py);
        const name = typeof feature.props.name === 'string' && feature.props.name ? feature.props.name : undefined;
        const rawElevation = feature.props.ele;
        const elevation = typeof rawElevation === 'number' && Number.isFinite(rawElevation) ? rawElevation : undefined;
        peaks.push({ center: { lon: lng, lat }, name, elevation });
      }
    }
  }
  return peaks;
}
