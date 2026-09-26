/**
 * Minimal Mapbox Vector Tile decoder.
 *
 * MapTiler's `outdoor` and `planet` tilesets are served as gzipped .pbf, so
 * callers pass the *decompressed* bytes in here. A whole tile at snap zoom
 * (13) is only a few KB, so decoding it per click is cheap.
 *
 * Output geometry stays in tile pixel space (integer offsets against the
 * layer's `extent`, y-down, origin at the tile's top-left); convert to
 * lng/lat with `tilePointToLngLat`.
 */

export type MVTTagValue = string | number | boolean;

export interface MVTFeature {
  id?: number;
  /** 1 = Point, 2 = LineString, 3 = Polygon (vector-tile spec). */
  type: number;
  props: Record<string, MVTTagValue>;
  /** Geometry as one or more parts; each part is a list of [px, py]. */
  parts: [number, number][][];
}

export interface MVTLayer {
  name: string;
  extent: number;
  features: MVTFeature[];
}

const DEFAULT_EXTENT = 4096;

class Reader {
  private pos = 0;

  constructor(private readonly buf: Uint8Array) {}

  get done(): boolean {
    return this.pos >= this.buf.byteLength;
  }

  readVarint(): number {
    let result = 0;
    let shift = 0;
    for (;;) {
      const byte = this.buf[this.pos++];
      result += (byte & 0x7f) * 2 ** shift;
      if ((byte & 0x80) === 0) break;
      shift += 7;
      if (shift > 63) throw new Error('Varint too long in vector tile');
    }
    return result;
  }

  readBytes(): Uint8Array {
    const length = this.readVarint();
    const bytes = this.buf.subarray(this.pos, this.pos + length);
    this.pos += length;
    return bytes;
  }

  readFixed32(): number {
    const dataView = new DataView(this.buf.buffer, this.buf.byteOffset, this.buf.byteLength);
    const value = dataView.getFloat32(this.pos, true);
    this.pos += 4;
    return value;
  }

  /** Skip an 8-byte fixed64 field. */
  skipFixed64(): void {
    this.pos += 8;
  }
}

function tagField(reader: Reader): { field: number; wireType: number } {
  const tag = reader.readVarint();
  return { field: tag >> 3, wireType: tag & 0x7 };
}

function skipField(reader: Reader, wireType: number): void {
  switch (wireType) {
    case 0: reader.readVarint(); break;
    case 1: reader.skipFixed64(); break;
    case 2: reader.readBytes(); break;
    case 5: reader.readFixed32(); break;
    default: throw new Error(`Unsupported wire type ${wireType} in vector tile`);
  }
}

/** Zig-zag decode (MVT geometry deltas and sint values are zig-zagged). */
function zigzag(value: number): number {
  return (value >>> 1) ^ -(value & 1);
}

function decodeValue(reader: Reader): MVTTagValue {
  const valueReader = new Reader(reader.readBytes());
  let value: MVTTagValue = true;
  while (!valueReader.done) {
    const { field, wireType } = tagField(valueReader);
    if (wireType === 0) {
      const raw = valueReader.readVarint();
      if (field === 4) value = raw; // int_value
      else if (field === 5) value = raw; // uint_value
      else if (field === 6) value = zigzag(raw); // sint_value
      else if (field === 7) value = raw !== 0; // bool_value
      else valueReader.readVarint();
    } else if (wireType === 2) {
      value = new TextDecoder().decode(valueReader.readBytes());
    } else if (wireType === 5) {
      value = valueReader.readFixed32();
    } else {
      valueReader.skipFixed64();
    }
  }
  return value;
}

function decodeGeometry(geometryBytes: Uint8Array, extent: number): [number, number][][] {
  const reader = new Reader(geometryBytes);
  const parts: [number, number][][] = [];
  let part: [number, number][] | null = null;
  let cursorX = 0;
  let cursorY = 0;
  while (!reader.done) {
    const command = reader.readVarint();
    const id = command & 0x7;
    const count = command >> 3;
    if (id === 1 || id === 2) {
      for (let i = 0; i < count; i++) {
        cursorX = Math.max(0, Math.min(extent - 1, cursorX + zigzag(reader.readVarint())));
        cursorY = Math.max(0, Math.min(extent - 1, cursorY + zigzag(reader.readVarint())));
        if (id === 1) {
          part = [[cursorX, cursorY]];
          parts.push(part);
        } else {
          if (part === null) part = [];
          part.push([cursorX, cursorY]);
        }
      }
    } else if (id === 7) {
      // ClosePath: implicit ring close; the cursor resets to the part's start.
      cursorX = 0;
      cursorY = 0;
      part = null;
    } else {
      return parts;
    }
  }
  return parts;
}

function decodeLayer(reader: Reader): MVTLayer {
  const layer: MVTLayer = { name: '', extent: DEFAULT_EXTENT, features: [] };
  const keys: string[] = [];
  const values: MVTTagValue[] = [];
  const rawFeatures: Uint8Array[] = [];
  let extent = DEFAULT_EXTENT;
  while (!reader.done) {
    const { field, wireType } = tagField(reader);
    if (field === 1) {
      layer.name = new TextDecoder().decode(reader.readBytes());
    } else if (field === 3) {
      keys.push(new TextDecoder().decode(reader.readBytes()));
    } else if (field === 4) {
      values.push(decodeValue(reader));
    } else if (field === 5) {
      extent = reader.readVarint();
      layer.extent = extent;
    } else if (field === 2) {
      rawFeatures.push(reader.readBytes());
    } else {
      skipField(reader, wireType);
    }
  }
  // Features may appear before keys/values on the wire, so resolve their tags
  // only once the dictionaries are complete.
  for (const featureBytes of rawFeatures) {
    const featureReader = new Reader(featureBytes);
    const feature: MVTFeature = { type: 0, props: {}, parts: [] };
    while (!featureReader.done) {
      const f = tagField(featureReader);
      if (f.field === 1) {
        feature.id = featureReader.readVarint();
      } else if (f.field === 3) {
        feature.type = featureReader.readVarint();
      } else if (f.field === 4) {
        feature.parts = decodeGeometry(featureReader.readBytes(), extent);
      } else if (f.field === 2) {
        const tagReader = new Reader(featureReader.readBytes());
        while (!tagReader.done) {
          const keyIndex = tagReader.readVarint();
          const valueIndex = tagReader.readVarint();
          const key = keys[keyIndex];
          const value = values[valueIndex];
          if (key !== undefined && value !== undefined) feature.props[key] = value;
        }
      } else {
        skipField(featureReader, f.wireType);
      }
    }
    layer.features.push(feature);
  }
  return layer;
}

/** Decode decompressed vector-tile bytes into its named layers. */
export function decodeTile(bytes: Uint8Array): MVTLayer[] {
  const reader = new Reader(bytes);
  const layers: MVTLayer[] = [];
  while (!reader.done) {
    const { field, wireType } = tagField(reader);
    if (field === 3 && wireType === 2) layers.push(decodeLayer(new Reader(reader.readBytes())));
    else skipField(reader, wireType);
  }
  return layers;
}

/** Find the first layer with the given name, or undefined. */
export function layerByName(layers: MVTLayer[], name: string): MVTLayer | undefined {
  return layers.find((layer) => layer.name === name);
}

/**
 * Convert a tile-pixel coordinate to lng/lat. `extent` is the layer extent;
 * (px, py) are y-down pixel offsets within the (z, x, y) tile.
 */
export function tilePointToLngLat(
  z: number,
  x: number,
  y: number,
  extent: number,
  px: number,
  py: number,
): { lng: number; lat: number } {
  const n = Math.PI - (2 * Math.PI * (y + py / extent)) / 2 ** z;
  return {
    lng: (x + px / extent) / 2 ** z * 360 - 180,
    lat: Math.atan(Math.sinh(n)) * (180 / Math.PI),
  };
}