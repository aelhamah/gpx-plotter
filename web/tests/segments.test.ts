import { describe, expect, it } from 'vitest';
import { metersPerPixel, segmentArrows, segmentBearingDegrees, segmentMidpoint } from '../src/segments';

const ORIGIN = { lat: 0, lon: 0 };
/** ~111 m north, ~111 m east at the equator. */
const NORTH = { lat: 0.001, lon: 0 };
const EAST = { lat: 0, lon: 0.001 };

describe('metersPerPixel', () => {
  it('is the Web Mercator ground resolution', () => {
    expect(metersPerPixel(0, 0)).toBeCloseTo(156543.03, 1);
    expect(metersPerPixel(10, 0)).toBeCloseTo(156543.03 / 1024, 3);
  });

  it('shrinks by the cosine of the latitude', () => {
    expect(metersPerPixel(12, 60)).toBeCloseTo(metersPerPixel(12, 0) * 0.5, 6);
  });
});

describe('segmentBearingDegrees', () => {
  it('reads 0 north, 90 east, 180 south, 270 west', () => {
    expect(segmentBearingDegrees(ORIGIN, NORTH)).toBeCloseTo(0, 6);
    expect(segmentBearingDegrees(ORIGIN, EAST)).toBeCloseTo(90, 6);
    expect(segmentBearingDegrees(NORTH, ORIGIN)).toBeCloseTo(180, 6);
    expect(segmentBearingDegrees(EAST, ORIGIN)).toBeCloseTo(270, 6);
  });

  it('splits the diagonal', () => {
    expect(segmentBearingDegrees(ORIGIN, { lat: 0.001, lon: 0.001 })).toBeCloseTo(45, 4);
  });

  it('wraps across the antimeridian instead of turning around', () => {
    const bearing = segmentBearingDegrees({ lat: 0, lon: 179.9 }, { lat: 0, lon: -179.9 });
    expect(bearing).toBeCloseTo(90, 4);
  });

  it('is 0 for a zero-length segment', () => {
    expect(segmentBearingDegrees(ORIGIN, ORIGIN)).toBe(0);
  });
});

describe('segmentMidpoint', () => {
  it('sits halfway along the drawn line', () => {
    const mid = segmentMidpoint(ORIGIN, { lat: 0.002, lon: 0.004 });
    expect(mid.lat).toBeCloseTo(0.001, 6);
    expect(mid.lon).toBeCloseTo(0.002, 6);
  });

  it('does not average the longitudes the wrong way across the antimeridian', () => {
    const mid = segmentMidpoint({ lat: 0, lon: 179.9 }, { lat: 0, lon: -179.9 });
    expect(Math.abs(mid.lon)).toBeCloseTo(180, 4);
  });
});

describe('segmentArrows', () => {
  const points = [ORIGIN, EAST, { lat: 0.001, lon: 0.002 }];

  it('puts one arrow on every segment, indexed from the start of the route', () => {
    const arrows = segmentArrows(points, 0, 14);
    expect(arrows).toHaveLength(2);
    expect(arrows.map((arrow) => arrow.index)).toEqual([0, 1]);
    expect(arrows[0].lon).toBeCloseTo(0.0005, 6);
    expect(arrows[0].meters).toBeCloseTo(111.19, 1);
    expect(arrows[0].bearing).toBeCloseTo(90, 6);
    expect(arrows[1].bearing).toBeCloseTo(45, 0);
  });

  it('returns nothing for an empty or single-point route', () => {
    expect(segmentArrows([], 0, 14)).toEqual([]);
    expect(segmentArrows([ORIGIN], 0, 14)).toEqual([]);
  });

  it('drops a segment that is shorter than the pixel spacing at this zoom', () => {
    // ~111 m of ground is well under 64 px at zoom 10 and well over it at 18.
    expect(segmentArrows(points, 64, 10)).toEqual([]);
    expect(segmentArrows(points, 64, 18)).toHaveLength(2);
  });

  it('keeps the long segment and drops the short one', () => {
    const mixed = [ORIGIN, { lat: 0, lon: 0.01 }, { lat: 0, lon: 0.01002 }];
    const arrows = segmentArrows(mixed, 64, 14);
    expect(arrows.map((arrow) => arrow.index)).toEqual([0]);
  });

  it('skips a repeated point, which has no direction to show', () => {
    expect(segmentArrows([ORIGIN, ORIGIN, EAST], 0, 14).map((arrow) => arrow.index)).toEqual([1]);
  });
});
