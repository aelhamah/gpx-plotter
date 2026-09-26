import { describe, expect, it } from 'vitest';
import {
  distanceMeters,
  nearestLine,
  nearestOnLine,
  nearestSnap,
  PEAK_SNAP_METERS,
  projectToSegment,
  TRAIL_FOLLOW_METERS,
  TRAIL_SNAP_METERS,
} from '../src/snap';

describe('distanceMeters', () => {
  it('is ~111.3 km per longitude degree at the equator', () => {
    expect(distanceMeters({ lon: 0, lat: 0 }, { lon: 0.001, lat: 0 })).toBeGreaterThan(100);
    expect(distanceMeters({ lon: 0, lat: 0 }, { lon: 0.001, lat: 0 })).toBeLessThan(130);
  });

  it('is ~110.6 km per latitude degree', () => {
    expect(distanceMeters({ lon: 0, lat: 0 }, { lon: 0, lat: 0.001 })).toBeGreaterThan(100);
    expect(distanceMeters({ lon: 0, lat: 0 }, { lon: 0, lat: 0.001 })).toBeLessThan(120);
  });

  it('shrinks along longitudes as latitude rises', () => {
    const equator = distanceMeters({ lon: 0, lat: 0 }, { lon: 0.001, lat: 0 });
    const high = distanceMeters({ lon: 0, lat: 45 }, { lon: 0.001, lat: 45 });
    expect(high).toBeLessThan(equator);
  });
});

describe('projectToSegment', () => {
  it('projects onto the interior of the segment', () => {
    const point = projectToSegment({ lon: 0.0002, lat: 0.0001 }, { lon: 0, lat: 0 }, { lon: 0.0004, lat: 0 });
    expect(point.lon).toBeCloseTo(0.0002, 9);
    expect(point.lat).toBeCloseTo(0, 9);
  });

  it('clamps to the segment start beyond point a', () => {
    const point = projectToSegment({ lon: -0.0001, lat: 0.0001 }, { lon: 0, lat: 0 }, { lon: 0.0004, lat: 0 });
    expect(point.lon).toBeCloseTo(0, 9);
  });

  it('clamps to the segment end beyond point b', () => {
    const point = projectToSegment({ lon: 0.0007, lat: 0 }, { lon: 0, lat: 0 }, { lon: 0.0004, lat: 0 });
    expect(point.lon).toBeCloseTo(0.0004, 9);
  });
});

describe('nearestOnLine', () => {
  it('snaps to the point of a single-point line within range', () => {
    const peak = { lon: -105, lat: 39 };
    const hit = nearestOnLine({ lon: -105, lat: 39.001 }, [peak], PEAK_SNAP_METERS);
    expect(hit).not.toBeNull();
    expect(hit!.point).toEqual(peak);
    expect(hit!.distanceMeters).toBeCloseTo(110.6, 0);
  });

  it('returns null beyond the max distance for a single point', () => {
    const peak = { lon: -105, lat: 39 };
    const hit = nearestOnLine({ lon: -105, lat: 39.01 }, [peak], PEAK_SNAP_METERS);
    expect(hit).toBeNull();
  });

  it('returns null for an empty line', () => {
    expect(nearestOnLine({ lon: 0, lat: 0 }, [], TRAIL_SNAP_METERS)).toBeNull();
  });
});

describe('nearestSnap', () => {
  const trail = [
    { lon: -105, lat: 39 },
    { lon: -104.99, lat: 39 },
  ];
  const other = [
    { lon: -105, lat: 39.02 },
    { lon: -104.99, lat: 39.02 },
  ];

  it('picks the closest of several lines', () => {
    // Point is far closer to `trail` (~0 dist) than to `other` (~2.2 km).
    const hit = nearestSnap({ lon: -105, lat: 39.0001 }, [trail, other], 100);
    expect(hit).not.toBeNull();
    expect(hit!.point.lon).toBeCloseTo(-105, 6);
    expect(hit!.point.lat).toBeCloseTo(39, 6);
  });

  it('rejects all lines beyond the threshold', () => {
    expect(nearestSnap({ lon: -105, lat: 39.05 }, [trail, other], 100)).toBeNull();
  });

  it('snaps a point near a sloped trail onto the trail line', () => {
    const sloped = [
      { lon: -105, lat: 39 },
      { lon: -104.99, lat: 39.001 },
    ];
    const hit = nearestSnap({ lon: -104.995, lat: 39.0004 }, [sloped], TRAIL_SNAP_METERS);
    expect(hit).not.toBeNull();
    expect(hit!.distanceMeters).toBeLessThan(TRAIL_SNAP_METERS);
  });
});

describe('nearestLine', () => {
  const trail = [
    { lon: -105, lat: 39 },
    { lon: -104.99, lat: 39 },
  ];

  it('returns the matched line and the projected segment', () => {
    const hit = nearestLine({ lon: -104.995, lat: 39.0002 }, [trail], TRAIL_SNAP_METERS);
    expect(hit).not.toBeNull();
    expect(hit!.line).toBe(trail);
    expect(hit!.result.segment).toBeDefined();
    expect(hit!.result.segment!.t).toBeCloseTo(0.5, 1);
    expect(hit!.result.segment!.a).toEqual(trail[0]);
    expect(hit!.result.segment!.b).toEqual(trail[1]);
  });

  it('has no segment for a single-point line (peaks)', () => {
    const hit = nearestLine({ lon: -105, lat: 39.0005 }, [[{ lon: -105, lat: 39 }]], PEAK_SNAP_METERS);
    expect(hit).not.toBeNull();
    expect(hit!.result.segment).toBeUndefined();
  });

  it('exposes a follow threshold well inside the snap threshold', () => {
    expect(TRAIL_FOLLOW_METERS).toBeLessThan(TRAIL_SNAP_METERS);
  });
});