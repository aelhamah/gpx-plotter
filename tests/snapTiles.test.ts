import { describe, expect, it } from 'vitest';
import { lngLatToTile } from '../src/dem';
import { inverseMercator } from '../src/geo';
import { SNAP_BASE_ZOOM, SNAP_MAX_ZOOM, snapTilesFor, snapZoomFor, tileSpanMeters } from '../src/snapTiles';

const LNG = -105.321;
const LAT = 39.685;
const Z = 13;

function tileOf(lng: number, lat: number, zoom = Z) {
  return lngLatToTile(lng, lat, zoom);
}

/** Meters from a point to each edge of the tile containing it. */
function edgesAwayMeters(lng: number, lat: number, zoom = Z) {
  const { x, y } = tileOf(lng, lat, zoom);
  const span = tileSpanMeters(lat, zoom);
  return {
    span,
    left: (x - Math.floor(x)) * span,
    right: (1 - (x - Math.floor(x))) * span,
    top: (y - Math.floor(y)) * span,
    bottom: (1 - (y - Math.floor(y))) * span,
  };
}

/**
 * A point `meters` from the named edge(s) of its tile. Latitude is offset
 * through the Mercator inverse, since tile y is not linear in degrees.
 */
function metersFromEdge(meters: number, edges: ('left' | 'right' | 'top' | 'bottom')[], zoom = Z) {
  const { x, y } = tileOf(LNG, LAT, zoom);
  const span = tileSpanMeters(LAT, zoom);
  let tx = x;
  let ty = y;
  if (edges.includes('left')) tx = Math.floor(x) + meters / span;
  if (edges.includes('right')) tx = Math.floor(x) + 1 - meters / span;
  if (edges.includes('top')) ty = Math.floor(y) + meters / span;
  if (edges.includes('bottom')) ty = Math.floor(y) + 1 - meters / span;
  return { lng: (tx / 2 ** zoom) * 360 - 180, lat: inverseMercator(ty / 2 ** zoom, tx / 2 ** zoom).lat };
}

const has = (tiles: { x: number; y: number }[], x: number, y: number) => tiles.some((t) => t.x === x && t.y === y);

describe('snapZoomFor', () => {
  it('tracks the map zoom once it is past the base zoom', () => {
    expect(snapZoomFor(13)).toBe(13);
    expect(snapZoomFor(15.2)).toBe(15);
    expect(snapZoomFor(16)).toBe(16);
  });

  it('never goes coarser than the base zoom', () => {
    // Zoom 8 carries no snap-worthy detail; reading it would snap to nothing.
    expect(snapZoomFor(8)).toBe(SNAP_BASE_ZOOM);
    expect(snapZoomFor(0)).toBe(SNAP_BASE_ZOOM);
  });

  it('never goes finer than the max zoom', () => {
    expect(snapZoomFor(22)).toBe(SNAP_MAX_ZOOM);
    expect(snapZoomFor(20, 15)).toBe(15);
  });

  it('rounds so panning at a fractional zoom reuses the cache', () => {
    expect(snapZoomFor(15.2)).toBe(snapZoomFor(15.4));
  });

  it('falls back to the base zoom for a nonsensical map zoom', () => {
    expect(snapZoomFor(Number.NaN)).toBe(SNAP_BASE_ZOOM);
  });
});

describe('tileSpanMeters', () => {
  it('shrinks with latitude', () => {
    expect(tileSpanMeters(0, 13)).toBeGreaterThan(tileSpanMeters(45, 13));
  });

  it('halves with each zoom level', () => {
    expect(tileSpanMeters(40, 14)).toBeCloseTo(tileSpanMeters(40, 13) / 2, 6);
  });

  it('stays finite and positive at the poles', () => {
    expect(tileSpanMeters(90, 13)).toBeGreaterThan(0);
    expect(Number.isFinite(tileSpanMeters(90, 13))).toBe(true);
  });
});

describe('snapTilesFor', () => {
  it('reads only the containing tile when the point is far from every edge', () => {
    // The old code always read exactly one tile, so a trail within 40m across a
    // tile boundary was unreachable and the working area stopped at an
    // invisible line — the reported "offset" in the snap region.
    const { x, y } = tileOf(LNG, LAT);
    const edges = edgesAwayMeters(LNG, LAT);
    expect(Math.min(edges.left, edges.right, edges.top, edges.bottom)).toBeGreaterThan(40);
    expect(snapTilesFor(LNG, LAT, Z, 40)).toEqual([{ x: Math.floor(x), y: Math.floor(y) }]);
  });

  it('adds the west neighbour when the radius reaches the left edge', () => {
    const { x, y } = tileOf(LNG, LAT);
    const near = metersFromEdge(10, ['left']);
    expect(edgesAwayMeters(near.lng, near.lat).left).toBeCloseTo(10, 6);

    const tiles = snapTilesFor(near.lng, near.lat, Z, 40);
    expect(tiles).toHaveLength(2);
    expect(has(tiles, Math.floor(x), Math.floor(y))).toBe(true);
    expect(has(tiles, Math.floor(x) - 1, Math.floor(y))).toBe(true);
  });

  it('adds the north neighbour when the radius reaches the top edge', () => {
    const { x, y } = tileOf(LNG, LAT);
    const near = metersFromEdge(10, ['top']);
    expect(edgesAwayMeters(near.lng, near.lat).top).toBeCloseTo(10, 1);

    const tiles = snapTilesFor(near.lng, near.lat, Z, 40);
    expect(has(tiles, Math.floor(x), Math.floor(y) - 1)).toBe(true);
  });

  it('adds the diagonal neighbour when two edges are both in reach', () => {
    const { x, y } = tileOf(LNG, LAT);
    const near = metersFromEdge(10, ['left', 'top']);
    const tiles = snapTilesFor(near.lng, near.lat, Z, 40);
    expect(tiles).toHaveLength(4);
    expect(has(tiles, Math.floor(x) - 1, Math.floor(y) - 1)).toBe(true);
  });

  it('does not add a neighbour that is further away than the radius', () => {
    const { x, y } = tileOf(LNG, LAT);
    const near = metersFromEdge(100, ['left']); // 100m out, radius is 40m
    const tiles = snapTilesFor(near.lng, near.lat, Z, 40);
    expect(tiles).toEqual([{ x: Math.floor(x), y: Math.floor(y) }]);
  });

  it('covers the peak radius as well as the trail radius', () => {
    // PEAK_SNAP_METERS is 250, so a summit just over a tile edge is reachable.
    const { x, y } = tileOf(LNG, LAT);
    const near = metersFromEdge(100, ['right']);
    expect(snapTilesFor(near.lng, near.lat, Z, 40)).toHaveLength(1);
    const wide = snapTilesFor(near.lng, near.lat, Z, 250);
    expect(wide).toHaveLength(2);
    expect(has(wide, Math.floor(x) + 1, Math.floor(y))).toBe(true);
  });

  it('always includes the tile containing the point', () => {
    const { x, y } = tileOf(LNG, LAT);
    for (const tiles of [snapTilesFor(LNG, LAT, Z, 0), snapTilesFor(LNG, LAT, Z, 40), snapTilesFor(LNG, LAT, Z, 250)]) {
      expect(has(tiles, Math.floor(x), Math.floor(y))).toBe(true);
    }
  });

  it('works the same at a detail zoom, where tiles are smaller', () => {
    // At z16 a tile is ~470m across here, so 250m genuinely spans neighbours.
    const detail = 16;
    const { x, y } = tileOf(LNG, LAT, detail);
    const near = metersFromEdge(10, ['left'], detail);
    const tiles = snapTilesFor(near.lng, near.lat, detail, 250);
    expect(has(tiles, Math.floor(x) - 1, Math.floor(y))).toBe(true);
  });

  it('clamps to the world instead of wrapping', () => {
    const tiles = snapTilesFor(179.999, 0, Z, 250);
    const maxTile = 2 ** Z - 1;
    for (const tile of tiles) {
      expect(tile.x).toBeGreaterThanOrEqual(0);
      expect(tile.x).toBeLessThanOrEqual(maxTile);
      expect(tile.y).toBeGreaterThanOrEqual(0);
      expect(tile.y).toBeLessThanOrEqual(maxTile);
    }
    expect(has(tiles, maxTile, 2 ** 12)).toBe(true);
  });

  it('never asks for more than the containing tile plus one ring', () => {
    // A runaway radius must not fan out into dozens of requests.
    expect(snapTilesFor(LNG, LAT, Z, 1_000_000).length).toBeLessThanOrEqual(9);
  });

  it('treats a zero or negative radius as the containing tile', () => {
    const { x, y } = tileOf(LNG, LAT);
    expect(snapTilesFor(LNG, LAT, Z, 0)).toEqual([{ x: Math.floor(x), y: Math.floor(y) }]);
    expect(snapTilesFor(LNG, LAT, Z, -5)).toEqual([{ x: Math.floor(x), y: Math.floor(y) }]);
  });

  it('returns nothing past the Mercator limit instead of looping forever', () => {
    // |lat| >= 85.05 makes the tile index non-finite; walking neighbours from an
    // infinite index never terminates, so this has to bail out.
    expect(snapTilesFor(0, 90, Z, 40)).toEqual([]);
    expect(snapTilesFor(0, -90, Z, 250)).toEqual([]);
    expect(snapTilesFor(Number.NaN, LAT, Z, 40)).toEqual([]);
  });
});
