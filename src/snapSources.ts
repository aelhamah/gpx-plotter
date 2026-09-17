/**
 * Fetches snap candidates from MapTiler's vector tilesets:
 *  - `outdoor`    → "trail" layer (marked hiking/biking routes) and
 *  - planet (v3)  → "transportation" layer, filtered to path-like classes,
 *                   because the `trail` layer only carries trails that belong
 *                   to a route relation (many ordinary paths are missing there).
 *  - planet (v3)  → "mountain_peak" layer for snapping waypoints onto peaks.
 *
 * Uses the same tileset URLs the map style already references, requesting a
 * single tile around the click's location and decoding it with `mvt`. Tile
 * bytes are cached per source/z/x/y so repeated clicks in one area do not
 * re-fetch. Any failure (network, tile 404, decode) silently yields no
 * candidates.
 */

import { OUTDOOR_TILE_URL, PLANET_TILE_URL } from './config';
import { lngLatToTile } from './dem';
import { decodeTile, layerByName, tilePointToLngLat, type MVTLayer } from './mvt';
import type { SnapPoint } from './snap';

const SNAP_ZOOM = 13;
export const SNAP_ZOOM_LEVEL = SNAP_ZOOM;
const CACHE_CAP = 96;

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

async function fetchDecodedTile(source: 'outdoor' | 'planet', lng: number, lat: number): Promise<DecodedTile> {
  const urlTemplate = source === 'outdoor' ? OUTDOOR_TILE_URL : PLANET_TILE_URL;
  const { x, y } = lngLatToTile(lng, lat, SNAP_ZOOM);
  const maxTile = 2 ** SNAP_ZOOM - 1;
  const cx = Math.max(0, Math.min(maxTile, Math.floor(x)));
  const cy = Math.max(0, Math.min(maxTile, Math.floor(y)));
  const key = `${source}/${SNAP_ZOOM}/${cx}/${cy}`;
  let job = tileCache.get(key);
  if (job) return job;
  job = (async () => {
    const url = urlTemplate.replace('{z}', String(SNAP_ZOOM)).replace('{x}', String(cx)).replace('{y}', String(cy));
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Snap tile ${key} failed with ${response.status}`);
    return { layers: decodeTile(new Uint8Array(await response.arrayBuffer())), z: SNAP_ZOOM, x: cx, y: cy };
  })();
  if (tileCache.size >= CACHE_CAP) {
    const oldest = tileCache.keys().next().value;
    if (oldest !== undefined) tileCache.delete(oldest);
  }
  tileCache.set(key, job);
  return job;
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

async function outdoorTrailLines(lng: number, lat: number): Promise<SnapPoint[][]> {
  const decoded = await fetchDecodedTile('outdoor', lng, lat);
  return linesFromLayer(decoded, 'trail');
}

async function transportPathLines(lng: number, lat: number): Promise<SnapPoint[][]> {
  const decoded = await fetchDecodedTile('planet', lng, lat);
  return linesFromLayer(decoded, 'transportation', (props) => typeof props.class === 'string' && TRAIL_CLASSES.has(props.class));
}

/**
 * Trail polylines near a point (lng/lat), combining the marked `trail` layer
 * with path-like `transportation` lines. Returns [] when both sources fail.
 */
export async function trailsNearPoint(lng: number, lat: number): Promise<SnapPoint[][]> {
  const [marked, paths] = await Promise.all([
    outdoorTrailLines(lng, lat).catch(() => []),
    transportPathLines(lng, lat).catch(() => []),
  ]);
  return [...marked, ...paths];
}

/** Peaks near a point, or [] on failure. */
export async function peaksNearPoint(lng: number, lat: number): Promise<PeakInfo[]> {
  try {
    const decoded = await fetchDecodedTile('planet', lng, lat);
    const peaks = layerByName(decoded.layers, 'mountain_peak');
    if (!peaks) return [];
    const list: PeakInfo[] = [];
    for (const feature of peaks.features) {
      if (feature.type !== 1) continue;
      for (const part of feature.parts) {
        const [px, py] = part[0] ?? [0, 0];
        const { lng, lat } = tilePointToLngLat(decoded.z, decoded.x, decoded.y, peaks.extent, px, py);
        const name = typeof feature.props.name === 'string' && feature.props.name ? feature.props.name : undefined;
        const rawElevation = feature.props.ele;
        const elevation = typeof rawElevation === 'number' && Number.isFinite(rawElevation) ? rawElevation : undefined;
        list.push({ center: { lon: lng, lat }, name, elevation });
      }
    }
    return list;
  } catch {
    return [];
  }
}
