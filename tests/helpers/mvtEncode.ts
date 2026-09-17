import { lngLatToTile } from '../../src/dem';

/**
 * Minimal Mapbox Vector Tile *encoder* solely for tests/fixtures, so the
 * decoder in src/mvt.ts is validated against real protobuf bytes. Geometry is
 * written in tile-pixel space (extent units) with zig-zag delta commands.
 */

interface FixtureFeature {
  type: number;
  props: Record<string, string | number | boolean>;
  parts: [number, number][][];
  /** Append a ClosePath command after each part with 3+ points. */
  close?: boolean;
}
interface FixtureLayer {
  name: string;
  extent?: number;
  features: FixtureFeature[];
}

function varint(value: number): number[] {
  if (value < 0) throw new Error('Negative varints unsupported in test encoder');
  const bytes: number[] = [];
  let v = value >>> 0;
  do {
    let byte = v & 0x7f;
    v = Math.floor(v / 2 ** 7);
    if (v !== 0) byte |= 0x80;
    bytes.push(byte);
  } while (v !== 0);
  return bytes;
}

function zigzag(value: number): number {
  return (value << 1) ^ (value >> 31);
}

function tag(field: number, wireType: number): number[] {
  return varint((field << 3) | wireType);
}

function lenBytes(field: number, payload: number[]): number[] {
  return [...tag(field, 2), ...varint(payload.length), ...payload];
}

function stringBytes(text: string): number[] {
  const bytes = new TextEncoder().encode(text);
  return [...bytes];
}

function valueBytes(value: string | number | boolean): number[] {
  const inner: number[] = [];
  if (typeof value === 'string') {
    inner.push(...lenBytes(1, stringBytes(value)));
  } else if (typeof value === 'boolean') {
    inner.push(...tag(7, 0), ...varint(value ? 1 : 0));
  } else if (Number.isInteger(value) && value >= 0) {
    inner.push(...tag(5, 0), ...varint(value));
  } else {
    inner.push(...tag(4, 0), ...varint(value));
  }
  return lenBytes(4, inner);
}

function geometryBytes(parts: [number, number][][], close = false): number[] {
  const packed: number[] = [];
  let cursorX = 0;
  let cursorY = 0;
  for (const part of parts) {
    const first = part[0];
    if (!first) continue;
    packed.push(...varint((1 << 3) | 1)); // MoveTo, one point (delta from the running cursor)
    packed.push(...varint(zigzag(first[0] - cursorX)), ...varint(zigzag(first[1] - cursorY)));
    cursorX = first[0];
    cursorY = first[1];
    if (part.length >= 2) packed.push(...varint(((part.length - 1) << 3) | 2)); // LineTo
    for (let i = 1; i < part.length; i++) {
      const [x, y] = part[i];
      packed.push(...varint(zigzag(x - cursorX)), ...varint(zigzag(y - cursorY)));
      cursorX = x;
      cursorY = y;
    }
    if (close && part.length >= 3) {
      packed.push(...varint((1 << 3) | 7)); // ClosePath
      cursorX = 0;
      cursorY = 0;
    }
  }
  return varint((4 << 3) | 2).concat(varint(packed.length), packed);
}

function encodeLayer(layer: FixtureLayer): number[] {
  const keys: string[] = [];
  const values: Array<string | number | boolean> = [];
  const valueIndexes = new Map<string, number>();
  const keyIndexes = new Map<string, number>();

  for (const feature of layer.features) {
    for (const key of Object.keys(feature.props)) {
      if (!keyIndexes.has(key)) keyIndexes.set(key, keys.length), keys.push(key);
    }
  }

  const features: number[] = [];
  for (const feature of layer.features) {
    const inner: number[] = [];
    inner.push(...tag(3, 0), ...varint(feature.type));
    const tagPairs: number[] = [];
    for (const [key, raw] of Object.entries(feature.props)) {
      const ki = keyIndexes.get(key)!;
      let vi = valueIndexes.get(String(raw));
      if (vi === undefined) {
        vi = values.length;
        values.push(raw);
        valueIndexes.set(String(raw), vi);
      }
      tagPairs.push(...varint(ki), ...varint(vi));
    }
    if (tagPairs.length > 0) inner.push(...lenBytes(2, tagPairs));
    inner.push(...geometryBytes(feature.parts, feature.close));
    features.push(lenBytes(2, inner));
  }

  const layerBytes: number[] = [];
  layerBytes.push(...lenBytes(1, stringBytes(layer.name)));
  // Emit features before keys/values, matching MapTiler's real tiles, so the
  // decoder must resolve tags in a second pass.
  for (const bytes of features) layerBytes.push(...bytes);
  layerBytes.push(...tag(5, 0), ...varint(layer.extent ?? 4096)); // extent = field 5 per MVT spec
  for (const key of keys) layerBytes.push(...lenBytes(3, stringBytes(key)));
  for (const value of values) layerBytes.push(...valueBytes(value));

  return lenBytes(3, layerBytes);
}

export function encodeTile(layers: FixtureLayer[]): Uint8Array {
  const tile: number[] = [];
  for (const layer of layers) tile.push(...encodeLayer(layer));
  return new Uint8Array(tile);
}

/** Inverse of src/mvt.ts tilePointToLngLat: lng/lat → tile-pixel offsets. */
export function lngLatToTilePx(
  lng: number,
  lat: number,
  z: number,
  x: number,
  y: number,
  extent: number,
): { px: number; py: number } {
  const world = 2 ** z;
  const fx = ((lng + 180) / 360) * world;
  const sin = Math.sin((lat * Math.PI) / 180);
  const fy = (0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * world;
  return { px: (fx - x) * extent, py: (fy - y) * extent };
}

export function tileCoordsFor(lng: number, lat: number, z: number): { x: number; y: number } {
  const { x, y } = lngLatToTile(lng, lat, z);
  return { x: Math.floor(x), y: Math.floor(y) };
}