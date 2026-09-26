import { TERRAIN_TILE_URL } from './config';

/**
 * Client-side decoder for MapTiler Terrain RGB tiles.
 *
 * Provides two things the app previously could not do without elevation in
 * the GPX file:
 *  1. `elevationAt()` — sample terrain elevation for any lng/lat (used to fill
 *     missing elevations on imported/drawn points so gain/loss/low/high and
 *     max slope always populate).
 *  2. `slopeCanvasForTile()` — a colorized slope-angle raster per DEM tile so
 *     the whole terrain can be shaded avalanche-style (`<20°` … `45°+`).
 *
 * Elevation model: R/G/B encode -10000 + (R*256*256 + G*256 + B) * 0.1 meters.
 */

export const DEM_MAX_ZOOM = 14;

interface TileData {
  width: number;
  height: number;
  elevations: Float32Array;
}

const tileCache = new Map<string, TileData>();
const pending = new Map<string, Promise<TileData>>();

export function lngLatToTile(lng: number, lat: number, z: number) {
  const world = 256 * Math.pow(2, z);
  const x = ((lng + 180) / 360) * world;
  const sin = Math.sin((lat * Math.PI) / 180);
  const y = (0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * world;
  return { x: x / 256, y: y / 256 };
}

export function tileNWLngLat(x: number, y: number, z: number) {
  const n = Math.PI - (2 * Math.PI * y) / Math.pow(2, z);
  const lat = Math.atan(Math.sinh(n)) * (180 / Math.PI);
  const lng = (x / Math.pow(2, z)) * 360 - 180;
  return { lng, lat };
}

async function fetchTileData(z: number, x: number, y: number): Promise<TileData> {
  const key = `${z}/${x}/${y}`;
  const cached = tileCache.get(key);
  if (cached) return cached;
  const inFlight = pending.get(key);
  if (inFlight) return inFlight;

  const job = (async () => {
    const url = TERRAIN_TILE_URL.replace('{z}', String(z)).replace('{x}', String(x)).replace('{y}', String(y));
    const response = await fetch(url);
    if (!response.ok) throw new Error(`DEM tile ${key} failed with ${response.status}`);
    const { width, height, data } = await decodeTilePixels(await response.blob());
    const tile: TileData = { width, height, elevations: decodeElevations(data) };
    if (tileCache.size > 400) tileCache.clear();
    tileCache.set(key, tile);
    return tile;
  })().finally(() => pending.delete(key));

  pending.set(key, job);
  return job;
}

/** Terrain-RGB pixel data → float32 elevations (meters): -10000 + (R*65536 + G*256 + B) * 0.1. */
export function decodeElevations(data: Uint8ClampedArray): Float32Array {
  const count = data.length / 4;
  const elevations = new Float32Array(count);
  for (let i = 0; i < count; i++) {
    const r = data[i * 4];
    const g = data[i * 4 + 1];
    const b = data[i * 4 + 2];
    elevations[i] = -10000 + (r * 256 * 256 + g * 256 + b) * 0.1;
  }
  return elevations;
}

/** Bilinear terrain elevation (meters) at a lng/lat, or undefined on failure. */
export async function elevationAt(lng: number, lat: number): Promise<number | undefined> {
  const z = DEM_MAX_ZOOM;
  const { x, y } = lngLatToTile(lng, lat, z);
  const tx = Math.floor(x);
  const ty = Math.floor(y);
  try {
    const tile = await fetchTileData(z, tx, ty);
    const fx = (x - tx) * tile.width;
    const fy = (y - ty) * tile.height;
    const x0 = Math.floor(fx);
    const y0 = Math.floor(fy);
    const dx = fx - x0;
    const dy = fy - y0;
    const i0 = Math.max(0, Math.min(tile.width - 2, x0));
    const j0 = Math.max(0, Math.min(tile.height - 2, y0));
    const at = (i: number, j: number) => tile.elevations[(j0 + j) * tile.width + (i0 + i)];
    const top = at(0, 0) * (1 - dx) + at(1, 0) * dx;
    const bottom = at(0, 1) * (1 - dx) + at(1, 1) * dx;
    return top * (1 - dy) + bottom * dy;
  } catch (error) {
    console.error('elevationAt failed for', lng, lat, error);
    return undefined;
  }
}

interface TilePixels { width: number; height: number; data: Uint8ClampedArray; }

function canvasFromImage(source: CanvasImageSource, width: number, height: number): TilePixels {
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext('2d', { willReadFrequently: true });
  if (!context) throw new Error('Canvas 2D context unavailable');
  context.drawImage(source, 0, 0);
  const image = context.getImageData(0, 0, width, height);
  return { width, height, data: image.data };
}

/** Decode a DEM tile blob to raw RGBA, via ImageBitmap with an <img> fallback. */
async function decodeTilePixels(blob: Blob): Promise<TilePixels> {
  try {
    const bitmap = await createImageBitmap(blob, { colorSpaceConversion: 'none', imageOrientation: 'none' });
    try {
      return canvasFromImage(bitmap, bitmap.width, bitmap.height);
    } finally {
      bitmap.close();
    }
  } catch (bitmapError) {
    // Some engines (e.g. older Safari) cannot decode WebP via createImageBitmap,
    // but a plain <img> decodes it reliably.
    try {
      const url = URL.createObjectURL(blob);
      try {
        const image = new Image();
        await new Promise<void>((resolve, reject) => {
          image.onload = () => resolve();
          image.onerror = () => reject(new Error('DEM tile image could not be decoded'));
          image.src = url;
        });
        return canvasFromImage(image, image.naturalWidth, image.naturalHeight);
      } finally {
        URL.revokeObjectURL(url);
      }
    } catch (imageError) {
      throw new AggregateError([bitmapError, imageError], 'All DEM tile decode paths failed');
    }
  }
}

/** Horizontal meters covered by one 256px tile pixel at the tile's mid-latitude and zoom. */
function metersPerPixel(z: number, midLatDeg: number) {
  const circumference = 40075016.686;
  return (circumference / Math.pow(2, z)) * Math.cos((midLatDeg * Math.PI) / 180);
}

/** CSS color per avalanche slope band (matches the on-map slope legend). */
export function slopeBandColorHex(slopeDeg: number): string {
  if (slopeDeg < 20) return '#22c55e';
  if (slopeDeg < 30) return '#eab308';
  if (slopeDeg < 35) return '#f97316';
  if (slopeDeg < 40) return '#ef4444';
  if (slopeDeg < 45) return '#a855f7';
  return '#111827';
}

function slopeColor(slopeDeg: number): [number, number, number, number] {
  const hex = slopeBandColorHex(slopeDeg);
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return [r, g, b, slopeDeg >= 45 ? 170 : 150];
}

function blankSlopeCanvas(width: number, height: number) {
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext('2d');
  return context ? { canvas, context } : null;
}

/**
 * Colorize a DEM elevation grid by slope angle into RGBA bytes (avalanche-style
 * bands: <20° green, <30° yellow, <35° orange, <40° red, <45° purple, else
 * near-black). Each pixel at (j,i) writes bytes at (j*width + i) * 4 — prior
 * versions indexed with j*width + i*4, which only painted the first rows of the
 * tile. `ppx` is meters per grid pixel; a wrong (too-large) value flattens all
 * slopes toward green.
 */
export function slopeRgba(
  elevations: ArrayLike<number>,
  width: number,
  height: number,
  ppx: number,
  step = 4,
): Uint8ClampedArray {
  const out = new Uint8ClampedArray(width * height * 4);
  for (let j = 0; j < height; j++) {
    for (let i = 0; i < width; i++) {
      const iL = clamp(i - step, 0, width - 1);
      const iR = clamp(i + step, 0, width - 1);
      const jU = clamp(j - step, 0, height - 1);
      const jD = clamp(j + step, 0, height - 1);
      const dzx = elevations[j * width + iR] - elevations[j * width + iL];
      const dzy = elevations[jD * width + i] - elevations[jU * width + i];
      const slope = Math.atan(Math.hypot(dzx, dzy) / (2 * step * ppx)) * (180 / Math.PI);
      const [r, g, b, a] = slopeColor(slope);
      const o = (j * width + i) * 4;
      out[o] = r;
      out[o + 1] = g;
      out[o + 2] = b;
      out[o + 3] = a;
    }
  }
  return out;
}

/** Colorized slope raster for a DEM tile at integer zoom z (256px scale). */
export async function slopeCanvasForTile(z: number, x: number, y: number): Promise<HTMLCanvasElement | null> {
  const { lng, lat } = tileNWLngLat(x, y, z);
  const data = await fetchTileData(z, x, y);
  const width = data.width;
  const height = data.height;
  const alloc = blankSlopeCanvas(width, height);
  if (!alloc) return null;
  const { canvas, context } = alloc;
  const image = context.createImageData(width, height);
  // Meters per DEM pixel: tile width at the tile's latitude, divided by the tile's pixel size.
  const ppx = metersPerPixel(z, lat + (180 / Math.pow(2, z)) / 2) / data.width;
  image.data.set(slopeRgba(data.elevations, width, height, ppx));
  context.putImageData(image, 0, 0);
  return canvas;
}

/** Web Mercator position in 512-CSS-pixel world units used by MapLibre's transform. */
export function worldMercator(lng: number, lat: number, zoom: number) {
  const world = 512 * Math.pow(2, zoom);
  const x = ((lng + 180) / 360) * world;
  const sin = Math.sin((lat * Math.PI) / 180);
  const y = (0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * world;
  return { x, y };
}

function clamp(value: number, min: number, max: number) {
  return value < min ? min : value > max ? max : value;
}