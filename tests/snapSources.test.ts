import { afterEach, describe, expect, it, vi } from 'vitest';
import { peaksNearPoint, SNAP_ZOOM_LEVEL, trailsNearPoint } from '../src/snapSources';
import { encodeTile, lngLatToTilePx, tileCoordsFor } from './helpers/mvtEncode';

const EXTENT = 4096;
const Z = SNAP_ZOOM_LEVEL;

function stubFetch(bytes: Uint8Array) {
  vi.stubGlobal(
    'fetch',
    vi.fn(async () => ({ ok: true, status: 200, arrayBuffer: async () => bytes.buffer as ArrayBuffer })),
  );
}

describe('trailsNearPoint', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('returns the trail line near a point, decoded back to lng/lat', async () => {
    const lng = -105.321;
    const lat = 39.685;
    const { x, y } = tileCoordsFor(lng, lat, Z);
    const trailLngLat = [
      { lon: lng - 0.001, lat },
      { lon: lng + 0.001, lat: lat + 0.0002 },
    ];
    const px = trailLngLat.map(({ lon, lat: lat2 }) => {
      const { px, py } = lngLatToTilePx(lon, lat2, Z, x, y, EXTENT);
      return [px, py];
    });
    stubFetch(
      encodeTile([
        {
          name: 'trail',
          extent: EXTENT,
          features: [{ type: 2, props: { class: 'hiking', name: 'Test Loop' }, parts: [px] }],
        },
      ]),
    );

    const lines = await trailsNearPoint(lng, lat);
    expect(lines.length).toBe(1);
    expect(lines[0].length).toBe(2);
    expect(lines[0][0].lon).toBeCloseTo(trailLngLat[0].lon, 4);
    expect(lines[0][0].lat).toBeCloseTo(trailLngLat[0].lat, 4);
    expect(lines[0][1].lon).toBeCloseTo(trailLngLat[1].lon, 4);
    expect(lines[0][1].lat).toBeCloseTo(trailLngLat[1].lat, 4);
  });

  it('returns [] when the fetch fails', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 404 })));
    const lines = await trailsNearPoint(-105.5, 39.6);
    expect(lines).toEqual([]);
  });

  it('returns [] when the tile has no trail layer', async () => {
    stubFetch(encodeTile([{ name: 'landuse', extent: EXTENT, features: [] }]));
    const lines = await trailsNearPoint(-105.6, 39.7);
    expect(lines).toEqual([]);
  });
});

describe('peaksNearPoint', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('returns peak centers, names, and elevations near a point', async () => {
    const lng = -106.44;
    const lat = 39.153;
    const { x, y } = tileCoordsFor(lng, lat, Z);
    const peak = { lon: lng + 0.0003, lat: lat + 0.0002 };
    const { px, py } = lngLatToTilePx(peak.lon, peak.lat, Z, x, y, EXTENT);
    stubFetch(
      encodeTile([
        {
          name: 'mountain_peak',
          extent: EXTENT,
          features: [{ type: 1, props: { name: 'Mount Massive', ele: 4398 }, parts: [[[px, py]]] }],
        },
      ]),
    );

    const peaks = await peaksNearPoint(lng, lat);
    expect(peaks.length).toBe(1);
    expect(peaks[0].name).toBe('Mount Massive');
    expect(peaks[0].elevation).toBe(4398);
    expect(peaks[0].center.lon).toBeCloseTo(peak.lon, 4);
    expect(peaks[0].center.lat).toBeCloseTo(peak.lat, 4);
  });

  it('ignores unnamed peaks (name optional)', async () => {
    const lng = -106.5;
    const lat = 39.2;
    const { x, y } = tileCoordsFor(lng, lat, Z);
    const { px, py } = lngLatToTilePx(lng, lat, Z, x, y, EXTENT);
    stubFetch(
      encodeTile([
        { name: 'mountain_peak', extent: EXTENT, features: [{ type: 1, props: { ele: 4102 }, parts: [[[px, py]]] }] },
      ]),
    );
    const peaks = await peaksNearPoint(lng, lat);
    expect(peaks[0].name).toBeUndefined();
    expect(peaks[0].elevation).toBe(4102);
  });
});