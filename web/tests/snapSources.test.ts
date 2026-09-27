import { afterEach, describe, expect, it, vi } from 'vitest';
import { peaksNearPoint, trailsNearPoint } from '../src/snapSources';
import { onServiceFailure } from '../src/serviceStatus';
import { SNAP_MIN_ZOOM, TILESET_MAX_ZOOM, snapZoomFor } from '../src/snapTiles';
import { PEAK_SNAP_METERS } from '../src/snap';
import { encodeTile, lngLatToTilePx, tileCoordsFor } from './helpers/mvtEncode';

const EXTENT = 4096;
const Z = SNAP_MIN_ZOOM;

function stubFetch(bytes: Uint8Array) {
  vi.stubGlobal(
    'fetch',
    vi.fn(async () => ({ ok: true, status: 200, arrayBuffer: async () => bytes.buffer as ArrayBuffer })),
  );
}

/** Every tile URL the reader requested, as `source/z/x/y`. */
function requestedTiles(fetchMock: ReturnType<typeof vi.fn>): string[] {
  return fetchMock.mock.calls
    .map(([url]) => String(url))
    .map((url) => url.replace(/^.*\/tiles\//, '').replace(/\.pbf.*$/, ''))
    .sort();
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

describe('which tiles a snap reads', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('reads at the zoom the map is showing, not a fixed one', async () => {
    stubFetch(encodeTile([]));
    const fetchMock = vi.mocked(fetch);
    await trailsNearPoint(-106.52, 39.53, 15);

    // A snap has to read the geometry the basemap is drawing, at the depth it
    // is drawing it: at z13 the tilesets have already dropped the minor paths a
    // click is aiming at.
    const zooms = requestedTiles(fetchMock).map((tile) => Number(tile.split('/')[1]));
    expect(zooms).toContain(15);
    expect(zooms).not.toContain(13);
  });

  it('clamps each tileset to the deepest zoom it actually serves', async () => {
    stubFetch(encodeTile([]));
    const fetchMock = vi.mocked(fetch);
    await trailsNearPoint(-106.12, 39.13, 15);

    // The planet tileset serves z15 but `outdoor` stops at z14, so at the
    // deepest snap zoom the marked-trail source has to step back rather than
    // request a tile the endpoint answers with a 400.
    const tiles = requestedTiles(fetchMock);
    expect(tiles.filter((tile) => tile.startsWith('v3/'))).not.toHaveLength(0);
    expect(tiles.filter((tile) => tile.startsWith('outdoor/'))).not.toHaveLength(0);
    for (const tile of tiles) {
      const [, zoom] = tile.split('/');
      expect(Number(zoom)).toBeLessThanOrEqual(TILESET_MAX_ZOOM[tile.startsWith('outdoor/') ? 'outdoor' : 'planet']);
    }
  });

  it('reads only the tiles the radius reaches, not a fixed ring', async () => {
    stubFetch(encodeTile([]));
    const fetchMock = vi.mocked(fetch);
    // Dead centre of a z15 tile, so a 40 m radius is ~470 m clear of every edge.
    await trailsNearPoint(...tileCentre(7000, 13000, 15), 15);

    // One tile per source. Rounding the ring up unconditionally would cost nine
    // fetches per source for the ordinary case of clicking mid-tile.
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('reads the neighbouring tile when the radius crosses an edge', async () => {
    stubFetch(encodeTile([]));
    const fetchMock = vi.mocked(fetch);
    const x = 7100;
    const y = 13100;
    // 5 m inside this tile's western edge, with the full 250 m peak radius, so a
    // candidate 30 m further west lives in the neighbour.
    const lat = latOfTileY(y + 0.5, 15);
    const nearEdgeLng = tileWestEdge(x, 15) + 5 / metersPerDegreeLon(lat);
    await trailsNearPoint(nearEdgeLng, lat, 15, PEAK_SNAP_METERS);
    expect(requestedTiles(fetchMock)).toContain(`v3/15/${x - 1}/${y}`);

    // Pull the radius in and the neighbour is no longer reachable.
    fetchMock.mockClear();
    await trailsNearPoint(nearEdgeLng, lat, 15, 1);
    expect(requestedTiles(fetchMock)).not.toContain(`v3/15/${x - 1}/${y}`);
  });
});

/** Centre of a tile: the point furthest from every tile edge. */
function tileCentre(x: number, y: number, zoom: number): [number, number] {
  return [tileWestEdge(x, zoom) + (360 / 2 ** zoom) * 0.5, latOfTileY(y + 0.5, zoom)];
}

function tileWestEdge(x: number, zoom: number): number {
  return (x / 2 ** zoom) * 360 - 180;
}

function latOfTileY(fractionalY: number, zoom: number): number {
  const n = Math.PI - (2 * Math.PI * fractionalY) / 2 ** zoom;
  return (Math.atan(Math.sinh(n)) * 180) / Math.PI;
}

function metersPerDegreeLon(lat: number): number {
  return 111320 * Math.cos((lat * Math.PI) / 180);
}

describe('tile cache', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('reuses a decoded tile instead of refetching it', async () => {
    stubFetch(encodeTile([]));
    const fetchMock = vi.mocked(fetch);
    const lng = -111.5;
    const lat = 35.2;
    await trailsNearPoint(lng, lat, Z);
    const afterFirst = fetchMock.mock.calls.length;
    await trailsNearPoint(lng, lat, Z);
    expect(fetchMock.mock.calls.length).toBe(afterFirst);
  });

  it('does not cache a failed read, so a later attempt can still succeed', async () => {
    const bytes = encodeTile([
      { name: 'trail', extent: EXTENT, features: [{ type: 2, props: {}, parts: [[[0, 0], [10, 10]]] }] },
    ]);
    let calls = 0;
    const fetchMock = vi.fn(async () => {
      calls++;
      // The first attempt is refused, as a rate limit or 5xx would be.
      if (calls === 1) return { ok: false, status: 429 };
      return { ok: true, status: 200, arrayBuffer: async () => bytes.buffer as ArrayBuffer };
    });
    vi.stubGlobal('fetch', fetchMock);

    // Distinct coordinates so this is a fresh tile rather than a cache hit.
    const lng = -111.71;
    const lat = 35.31;
    expect(await trailsNearPoint(lng, lat, Z)).toEqual([]);
    expect(await trailsNearPoint(lng, lat, Z).then((lines) => lines.length)).toBeGreaterThan(0);
  });
});

describe('failure reporting', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('says so when every tile of a snap fails', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 500 })));
    const seen: string[] = [];
    const off = onServiceFailure((issue) => seen.push(issue.kind));

    expect(await trailsNearPoint(-112.4, 36.9, Z)).toEqual([]);
    off();

    // Without this, an outage and "there is no trail here" look the same.
    expect(seen).toContain('snap');
  });

  it('says nothing when a snap simply finds no trail', async () => {
    stubFetch(encodeTile([{ name: 'transportation', extent: EXTENT, features: [] }]));
    const seen: string[] = [];
    const off = onServiceFailure((issue) => seen.push(issue.kind));

    expect(await trailsNearPoint(-113.4, 37.9, Z)).toEqual([]);
    off();

    expect(seen).toHaveLength(0);
  });

  it('says nothing when only some tiles of a snap fail', async () => {
    // A single unreachable tile costs its own candidates, not the whole snap.
    const bytes = encodeTile([
      { name: 'trail', extent: EXTENT, features: [{ type: 2, props: {}, parts: [[[0, 0], [10, 10]]] }] },
    ]);
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => {
        if (String(url).includes('/tiles/outdoor/')) return { ok: false, status: 500 };
        return { ok: true, status: 200, arrayBuffer: async () => bytes.buffer as ArrayBuffer };
      }),
    );
    const seen: string[] = [];
    const off = onServiceFailure((issue) => seen.push(issue.kind));

    expect(await trailsNearPoint(-114.4, 38.9, Z)).toEqual([]);
    off();

    expect(seen).toHaveLength(0);
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

  it('returns [] when the peak tiles cannot be read', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 404 })));
    const peaks = await peaksNearPoint(-106.77, 39.42, Z);
    expect(peaks).toEqual([]);
  });
});
