import { afterEach, describe, expect, it, vi } from 'vitest';
import { lngLatToTile } from '../src/dem';
import { peaksNearPoint, trailsNearPoint } from '../src/snapSources';
import { SNAP_BASE_ZOOM, snapTilesFor, tileSpanMeters } from '../src/snapTiles';
import { TRAIL_SNAP_METERS } from '../src/snap';
import { encodeTile, lngLatToTilePx, tileCoordsFor } from './helpers/mvtEncode';

const EXTENT = 4096;
const Z = SNAP_BASE_ZOOM;

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

  it('falls back to path-like transportation lines (trail layer missing)', async () => {
    const lng = -106.81;
    const lat = 39.655;
    const { x, y } = tileCoordsFor(lng, lat, Z);
    const px = (lon: number, lat2: number) => {
      const { px: pxv, py } = lngLatToTilePx(lon, lat2, Z, x, y, EXTENT);
      return [pxv, py];
    };
    const pathLine = [px(lng - 0.0005, lat), px(lng + 0.0005, lat)];
    const roadLine = [px(lng - 0.0005, lat - 0.001), px(lng + 0.0005, lat - 0.001)];
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => {
        const bytes = String(url).includes('/tiles/outdoor/')
          ? encodeTile([])
          : encodeTile([
              {
                name: 'transportation',
                extent: EXTENT,
                features: [
                  { type: 2, props: { class: 'path' }, parts: [pathLine] },
                  { type: 2, props: { class: 'primary' }, parts: [roadLine] },
                  { type: 1, props: { class: 'path' }, parts: [[[0, 0]]] },
                ],
              },
            ]);
        return { ok: true, status: 200, arrayBuffer: async () => bytes.buffer as ArrayBuffer };
      }),
    );

    const lines = await trailsNearPoint(lng, lat);
    expect(lines.length).toBe(1);
    expect(lines[0][0].lon).toBeCloseTo(lng - 0.0005, 4);
    expect(lines[0][1].lon).toBeCloseTo(lng + 0.0005, 4);
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

/** A `trail` + `transportation` tile, so either source can yield a line. */
function trailTile(lng: number, lat: number, zoom: number) {
  const { x, y } = tileCoordsFor(lng, lat, zoom);
  const px = (lon: number, lat2: number) => {
    const { px: pxv, py } = lngLatToTilePx(lon, lat2, zoom, x, y, EXTENT);
    return [pxv, py];
  };
  const line = [px(lng - 0.0005, lat), px(lng + 0.0005, lat)];
  return encodeTile([
    { name: 'trail', extent: EXTENT, features: [{ type: 2, props: { class: 'hiking' }, parts: [line] }] },
    { name: 'transportation', extent: EXTENT, features: [{ type: 2, props: { class: 'path' }, parts: [line] }] },
  ]);
}

/** The zoom a tile URL was requested at. */
const zoomOf = (url: string) => Number(/\/tiles\/[^/]+\/(\d+)\//.exec(url)?.[1]);

/** A longitude sitting `meters` short of its tile's west edge, so two tiles are read. */
function nearWestEdge(lng: number, lat: number, meters: number, zoom: number) {
  const { x } = lngLatToTile(lng, lat, zoom);
  const target = meters / tileSpanMeters(lat, zoom);
  return lng + (target - (x - Math.floor(x))) * (360 / 2 ** zoom);
}

describe('snap tile failures are not cached', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('retries a tile that failed to fetch', async () => {
    // Regression: the rejected promise was memoised, so one flaky response left
    // snapping dead in that tile for the rest of the session.
    const lng = -105.91;
    const lat = 39.93;
    const bytes = trailTile(lng, lat, Z);
    let failing = true;
    const fetchMock = vi.fn(async () =>
      failing
        ? { ok: false, status: 503 }
        : { ok: true, status: 200, arrayBuffer: async () => bytes.buffer as ArrayBuffer },
    );
    vi.stubGlobal('fetch', fetchMock);

    expect(await trailsNearPoint(lng, lat)).toEqual([]);

    failing = false;
    const before = fetchMock.mock.calls.length;
    const lines = await trailsNearPoint(lng, lat);
    expect(fetchMock.mock.calls.length).toBeGreaterThan(before);
    expect(lines.length).toBeGreaterThan(0);
  });

  it('keeps the tiles that did load when a sibling tile 404s', async () => {
    // A point near a tile edge reads more than one tile; one failure must not
    // discard the candidates from the tiles alongside it.
    const lat = 39.95;
    const lng = nearWestEdge(-106.7, lat, 10, Z);
    const bytes = trailTile(lng, lat, Z);
    const tiles = snapTilesFor(lng, lat, Z, TRAIL_SNAP_METERS);
    expect(tiles.length).toBeGreaterThan(1);
    const broken = `/${tiles[0].x}/${tiles[0].y}.pbf`;

    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) =>
        String(url).includes(broken)
          ? { ok: false, status: 404 }
          : { ok: true, status: 200, arrayBuffer: async () => bytes.buffer as ArrayBuffer },
      ),
    );

    const lines = await trailsNearPoint(lng, lat);
    expect(lines.length).toBeGreaterThan(0);
  });
});

describe('snap detail zoom', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('reads candidates at the requested detail zoom', async () => {
    const lng = -105.71;
    const lat = 39.41;
    const bytes = trailTile(lng, lat, Z);
    const zooms: number[] = [];
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => {
        zooms.push(zoomOf(String(url)));
        return { ok: true, status: 200, arrayBuffer: async () => bytes.buffer as ArrayBuffer };
      }),
    );

    const lines = await trailsNearPoint(lng, lat, 15);
    expect(lines.length).toBeGreaterThan(0);
    expect(new Set(zooms)).toEqual(new Set([15]));
  });

  it('falls back to the base zoom when the detail tile has no candidates', async () => {
    // Vector tiles thin out and get generalized as zoom rises, so a detail read
    // can come back empty. Snapping must degrade to the old behaviour, not to
    // no snapping at all.
    const lng = -105.72;
    const lat = 39.42;
    const bytes = trailTile(lng, lat, Z);
    const zooms: number[] = [];
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => {
        const zoom = zoomOf(String(url));
        zooms.push(zoom);
        const payload = zoom === Z ? bytes : encodeTile([]);
        return { ok: true, status: 200, arrayBuffer: async () => payload.buffer as ArrayBuffer };
      }),
    );

    const lines = await trailsNearPoint(lng, lat, 16);
    expect(lines.length).toBeGreaterThan(0);
    expect(zooms).toContain(16);
    expect(zooms).toContain(Z);
  });

  it('falls back for peaks too', async () => {
    const lng = -106.41;
    const lat = 39.16;
    const { x, y } = tileCoordsFor(lng, lat, Z);
    const { px, py } = lngLatToTilePx(lng + 0.0002, lat, Z, x, y, EXTENT);
    const base = encodeTile([
      { name: 'mountain_peak', extent: EXTENT, features: [{ type: 1, props: { name: 'Fallback Peak', ele: 4000 }, parts: [[[px, py]]] }] },
    ]);
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => {
        const payload = zoomOf(String(url)) === Z ? base : encodeTile([]);
        return { ok: true, status: 200, arrayBuffer: async () => payload.buffer as ArrayBuffer };
      }),
    );

    const peaks = await peaksNearPoint(lng, lat, 15);
    expect(peaks.map((p) => p.name)).toContain('Fallback Peak');
  });

  it('does not re-read the base zoom when the detail tile has candidates', async () => {
    const lng = -105.73;
    const lat = 39.43;
    const bytes = trailTile(lng, lat, Z);
    const zooms: number[] = [];
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => {
        zooms.push(zoomOf(String(url)));
        return { ok: true, status: 200, arrayBuffer: async () => bytes.buffer as ArrayBuffer };
      }),
    );

    await trailsNearPoint(lng, lat, 14);
    expect(zooms).not.toContain(Z);
  });
});