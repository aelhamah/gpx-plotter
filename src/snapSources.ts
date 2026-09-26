/**
 * Fetches snap candidates from MapTiler's vector tilesets:
 *  - `outdoor`    → "trail" layer (marked hiking/biking routes) and
 *  - planet (v3)  → "transportation" layer, filtered to path-like classes,
 *                   because the `trail` layer only carries trails that belong
 *                   to a route relation (many ordinary paths are missing there).
 *  - planet (v3)  → "mountain_peak" layer for snapping waypoints onto peaks.
 *
 * Uses the same tileset URLs the map style already references, decoding the
 * tiles around the click's location with `mvt`. Which tiles those are, and at
 * what zoom, comes from `snapTiles` (tile coverage for the snap radius, zoom
 * tracking the map). Tile bytes are cached per source/z/x/y so repeated clicks
 * in one area do not re-fetch. A tile that fails to fetch or decode is dropped
 * and evicted from the cache, so the next click retries instead of being stuck
 * with the failure.
 */

import { OUTDOOR_TILE_URL, PLANET_TILE_URL } from './config';
import { decodeTile, layerByName, tilePointToLngLat, type MVTLayer } from './mvt';
import { PEAK_SNAP_METERS, TRAIL_SNAP_METERS, type SnapPoint } from './snap';
import { SNAP_BASE_ZOOM, snapTilesFor, type TileCoord } from './snapTiles';

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

async function fetchDecodedTile(source: 'outdoor' | 'planet', tile: TileCoord, zoom: number): Promise<DecodedTile> {
  const urlTemplate = source === 'outdoor' ? OUTDOOR_TILE_URL : PLANET_TILE_URL;
  const key = `${source}/${zoom}/${tile.x}/${tile.y}`;
  let job = tileCache.get(key);
  if (job) return job;
  job = (async () => {
    const url = urlTemplate
      .replace('{z}', String(zoom))
      .replace('{x}', String(tile.x))
      .replace('{y}', String(tile.y));
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Snap tile ${key} failed with ${response.status}`);
    return { layers: decodeTile(new Uint8Array(await response.arrayBuffer())), z: zoom, x: tile.x, y: tile.y };
  })();
  // A failed tile must not be remembered: the cache would keep serving the
  // rejected promise and snapping would stay dead in this tile for the rest of
  // the session. Evict on rejection so the next click tries again. The catch
  // also marks `job` as handled, leaving the rejection for the caller.
  job.catch(() => {
    if (tileCache.get(key) === job) tileCache.delete(key);
  });
  if (tileCache.size >= CACHE_CAP) {
    const oldest = tileCache.keys().next().value;
    if (oldest !== undefined) tileCache.delete(oldest);
  }
  tileCache.set(key, job);
  return job;
}

/** Decode every tile around a point, dropping the ones that fail. */
async function tilesNear(source: 'outdoor' | 'planet', lng: number, lat: number, zoom: number, radiusMeters: number) {
  const tiles = snapTilesFor(lng, lat, zoom, radiusMeters);
  const decoded = await Promise.all(tiles.map((tile) => fetchDecodedTile(source, tile, zoom).catch(() => null)));
  return decoded.filter((tile): tile is DecodedTile => tile !== null);
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

async function outdoorTrailLines(lng: number, lat: number, zoom: number, radiusMeters: number): Promise<SnapPoint[][]> {
  const decoded = await tilesNear('outdoor', lng, lat, zoom, radiusMeters);
  return decoded.flatMap((tile) => linesFromLayer(tile, 'trail'));
}

async function transportPathLines(lng: number, lat: number, zoom: number, radiusMeters: number): Promise<SnapPoint[][]> {
  const decoded = await tilesNear('planet', lng, lat, zoom, radiusMeters);
  return decoded.flatMap((tile) =>
    linesFromLayer(tile, 'transportation', (props) => typeof props.class === 'string' && TRAIL_CLASSES.has(props.class)),
  );
}

async function trailsAtZoom(lng: number, lat: number, zoom: number, radiusMeters: number): Promise<SnapPoint[][]> {
  const [marked, paths] = await Promise.all([
    outdoorTrailLines(lng, lat, zoom, radiusMeters).catch(() => []),
    transportPathLines(lng, lat, zoom, radiusMeters).catch(() => []),
  ]);
  return [...marked, ...paths];
}

/**
 * Trail polylines near a point (lng/lat), combining the marked `trail` layer
 * with path-like `transportation` lines. Every tile within `radiusMeters` is
 * read, so a trail just across a tile boundary still snaps.
 *
 * `zoom` lets the caller ask for detail matching the current map zoom. Tilesets
 * thin out and are generalized at high zoom, so a detail read that comes back
 * empty falls back to {@link SNAP_BASE_ZOOM} rather than silently not snapping.
 */
export async function trailsNearPoint(lng: number, lat: number, zoom = SNAP_BASE_ZOOM, radiusMeters = TRAIL_SNAP_METERS): Promise<SnapPoint[][]> {
  const lines = await trailsAtZoom(lng, lat, zoom, radiusMeters);
  if (lines.length > 0 || zoom <= SNAP_BASE_ZOOM) return lines;
  return trailsAtZoom(lng, lat, SNAP_BASE_ZOOM, radiusMeters);
}

async function peaksAtZoom(lng: number, lat: number, zoom: number, radiusMeters: number): Promise<PeakInfo[]> {
  const decoded = await tilesNear('planet', lng, lat, zoom, radiusMeters);
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

/** Peaks near a point, or [] on failure. Same detail-zoom fallback as trails. */
export async function peaksNearPoint(lng: number, lat: number, zoom = SNAP_BASE_ZOOM, radiusMeters = PEAK_SNAP_METERS): Promise<PeakInfo[]> {
  const peaks = await peaksAtZoom(lng, lat, zoom, radiusMeters);
  if (peaks.length > 0 || zoom <= SNAP_BASE_ZOOM) return peaks;
  return peaksAtZoom(lng, lat, SNAP_BASE_ZOOM, radiusMeters);
}
