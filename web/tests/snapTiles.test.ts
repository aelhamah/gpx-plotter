import { describe, expect, it } from 'vitest';
import {
  SNAP_MAX_ZOOM,
  SNAP_MIN_ZOOM,
  TILESET_MAX_ZOOM,
  snapZoomFor,
  tileSpanMeters,
  tilesNear,
  zoomForTileset,
} from '../src/snapTiles';

const EQUATOR_METERS = 40075016.686;

describe('snapZoomFor', () => {
  it('follows the map zoom inside the range the snap tilesets serve', () => {
    expect(snapZoomFor(14)).toBe(14);
    expect(snapZoomFor(15)).toBe(15);
  });

  it('never asks for a zoom the tilesets do not have', () => {
    expect(snapZoomFor(18)).toBe(SNAP_MAX_ZOOM);
    expect(snapZoomFor(20)).toBe(SNAP_MAX_ZOOM);
  });

  it('never drops to a zoom where the tilesets have discarded minor paths', () => {
    // z12 emits no path-like transportation classes at all, so a click snapped
    // there would find nothing even though the basemap is drawing trails.
    expect(snapZoomFor(8)).toBe(SNAP_MIN_ZOOM);
    expect(snapZoomFor(12.4)).toBe(SNAP_MIN_ZOOM);
  });

  it('rounds, so panning at a fractional zoom reuses the same tiles', () => {
    expect(snapZoomFor(14.2)).toBe(14);
    expect(snapZoomFor(14.4)).toBe(14);
    expect(snapZoomFor(14.6)).toBe(15);
    // The map reports a fractional zoom, but the cache key only changes at a
    // rounding boundary rather than on every wheel notch.
    expect(snapZoomFor(14.2)).toBe(snapZoomFor(14.4));
  });

  it('falls back to a usable zoom for a zoom the map cannot report', () => {
    expect(snapZoomFor(Number.NaN)).toBe(SNAP_MIN_ZOOM);
    expect(snapZoomFor(Number.POSITIVE_INFINITY)).toBe(SNAP_MIN_ZOOM);
    expect(snapZoomFor(Number.NEGATIVE_INFINITY)).toBe(SNAP_MIN_ZOOM);
  });
});

describe('zoomForTileset', () => {
  it('clamps each tileset to the deepest zoom it actually serves', () => {
    // outdoor stops at z14 and planet at z15; asking either for more is a 400.
    expect(zoomForTileset(15, 'outdoor')).toBe(TILESET_MAX_ZOOM.outdoor);
    expect(zoomForTileset(15, 'planet')).toBe(TILESET_MAX_ZOOM.planet);
    expect(zoomForTileset(14, 'outdoor')).toBe(14);
    expect(zoomForTileset(12, 'planet')).toBe(12);
  });

  it('cannot be pushed below zero', () => {
    expect(zoomForTileset(-4, 'planet')).toBe(0);
  });

  it('keeps every snap zoom within what at least one tileset serves', () => {
    for (let zoom = 8; zoom <= 20; zoom++) {
      expect(zoomForTileset(zoom, 'planet')).toBeLessThanOrEqual(SNAP_MAX_ZOOM);
      expect(zoomForTileset(zoom, 'outdoor')).toBeLessThanOrEqual(TILESET_MAX_ZOOM.outdoor);
    }
  });
});

describe('tileSpanMeters', () => {
  it('shrinks with zoom by a factor of two', () => {
    expect(tileSpanMeters(0, 14)).toBeCloseTo(tileSpanMeters(0, 15) * 2, 6);
  });

  it('is the full world width at the equator on z0', () => {
    expect(tileSpanMeters(0, 0)).toBeCloseTo(EQUATOR_METERS, 3);
  });

  it('narrows with the cosine of latitude', () => {
    expect(tileSpanMeters(60, 14)).toBeCloseTo(tileSpanMeters(0, 14) * 0.5, 3);
  });

  it('stays finite at the poles instead of collapsing to zero', () => {
    expect(tileSpanMeters(90, 14)).toBeGreaterThan(0);
    expect(Number.isFinite(tileSpanMeters(90, 14))).toBe(true);
  });
});

describe('tilesNear', () => {
  const LNG = -106.52;
  const LAT = 39.53;
  const PEAK_RADIUS_M = 250;

  it('returns only the containing tile when the radius cannot leave it', () => {
    // The common case, and the one that decides cost: a 40 m trail snap well
    // inside a ~944 m z15 tile must not fan out to nine fetches per source.
    const tiles = tilesNear(LNG, LAT, 15, 10);
    expect(tiles.length).toBe(1);
    expect(tiles[0]).toEqual({ x: 6688, y: 12460 });
  });

  it('adds the neighbours once the radius actually reaches a tile edge', () => {
    // Same point and radius, but a shallower zoom means a wider tile, so the
    // question is asked against the edge it is genuinely near.
    expect(tilesNear(LNG, LAT, 15, PEAK_RADIUS_M).length).toBeGreaterThan(1);
  });

  it('finds the neighbour holding a candidate just across an edge', () => {
    // A point 20 m from the western edge of its tile, with a 250 m radius: a
    // trail 30 m to the west lives in the tile this query has to include.
    const westEdge = tileX(LNG, 15);
    const nearWest = lngOfTileX(westEdge, 15) + 20 / metersPerDegreeLon(LAT);
    const tiles = tilesNear(nearWest, LAT, 15, PEAK_RADIUS_M);
    expect(tiles.map((tile) => tile.x)).toContain(westEdge - 1);

    // Pull the radius in and the neighbour is no longer reachable.
    expect(tilesNear(nearWest, LAT, 15, 5).map((tile) => tile.x)).not.toContain(westEdge - 1);
  });

  it('covers the point itself', () => {
    for (const zoom of [14, 15]) {
      const tiles = tilesNear(LNG, LAT, zoom, 40);
      const inside = tiles.some((tile) => tileX(LNG, zoom) === tile.x && tileY(LAT, zoom) === tile.y);
      expect(inside).toBe(true);
    }
  });

  it('never asks for a tile outside the world', () => {
    const nearDateLine = tilesNear(179.999, 0, 15, 4000);
    const max = 2 ** 15 - 1;
    for (const tile of nearDateLine) {
      expect(tile.x).toBeLessThanOrEqual(max);
      expect(tile.y).toBeGreaterThanOrEqual(0);
    }
    // The far side of the antimeridian wraps, so the ring must still contain
    // the tile the point is actually in.
    expect(nearDateLine.some((tile) => tile.x === max)).toBe(true);
  });

  it('clamps a negative radius to the containing tile', () => {
    expect(tilesNear(LNG, LAT, 15, -100).length).toBe(1);
  });

  it('returns nothing for coordinates that are not a place', () => {
    expect(tilesNear(Number.NaN, LAT, 15, 40)).toEqual([]);
    expect(tilesNear(LNG, Number.NaN, 15, 40)).toEqual([]);
  });

  it('never grows past a 3x3 ring, however large the radius', () => {
    // Over-fetching is harmless; unbounded growth would be a request storm.
    expect(tilesNear(LNG, LAT, 15, 500000).length).toBe(9);
  });
});

function metersPerDegreeLon(lat: number): number {
  return 111320 * Math.cos((lat * Math.PI) / 180);
}

function tileX(lng: number, zoom: number): number {
  return Math.floor(((lng + 180) / 360) * 2 ** zoom);
}

/** Longitude of a tile's western edge. */
function lngOfTileX(x: number, zoom: number): number {
  return (x / 2 ** zoom) * 360 - 180;
}

function tileY(lat: number, zoom: number): number {
  const sin = Math.sin((lat * Math.PI) / 180);
  return Math.floor((0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * 2 ** zoom);
}
