import { describe, it, expect } from 'vitest';
import {
  haversineMeters,
  mercatorX,
  mercatorY,
  inverseMercator,
  routeProfilePoints,
  summarizeProfile,
  segmentSlopeDegrees,
} from '../src/geo';

describe('mercator helpers', () => {
  it('round-trips a point through mercator and back', () => {
    const lat = 39.5;
    const lng = -107.32;
    const { lat: lat2, lng: lng2 } = inverseMercator(mercatorY(lat), mercatorX(lng));
    expect(lat2).toBeCloseTo(lat, 9);
    expect(lng2).toBeCloseTo(lng, 9);
  });
  it('keeps x within [0,1) and handles the antimeridian', () => {
    expect(mercatorX(-180)).toBeCloseTo(0, 9);
    expect(mercatorX(180)).toBeCloseTo(1, 9);
    const { lat, lng } = inverseMercator(0.5, 0.999);
    expect(lat).toBeCloseTo(0, 6);
    expect(lng).toBeCloseTo(179.64, 2);
  });
});

describe('routeProfilePoints', () => {
  it('interpolates a long segment at the requested spacing and preserves endpoints', () => {
    const a = { lat: 0, lon: 0 };
    const b = { lat: 0, lon: 1 }; // ~111 km along the equator
    const profile = routeProfilePoints([a, b], 1000);
    expect(profile.length).toBeGreaterThan(100);
    expect(profile.length).toBeLessThan(120);
    expect(profile[0]).toEqual(a);
    expect(profile[profile.length - 1]).toEqual(b);
    for (let i = 1; i < profile.length - 1; i++) {
      const gap = haversineMeters(profile[i - 1], profile[i]);
      expect(gap).toBeLessThanOrEqual(2000);
      expect(gap).toBeGreaterThan(400);
    }
  });
  it('keeps short segments verbatim with no interior samples', () => {
    const a = { lat: 39.5, lon: -107.3 };
    const b = { lat: 39.501, lon: -107.3 }; // ~110 m
    const profile = routeProfilePoints([a, b], 30 * 4);
    expect(profile).toEqual([a, b]);
  });
  it('does not create gaps across the antimeridian', () => {
    const a = { lat: 0, lon: 179.9 };
    const b = { lat: 0, lon: -179.9 };
    const profile = routeProfilePoints([a, b], 2000);
    expect(profile[0]).toEqual(a);
    expect(profile[profile.length - 1]).toEqual(b);
    for (const p of profile) {
      expect(Math.abs(p.lon)).toBeGreaterThan(170); // stays near the line, not a world-spanning jump
    }
  });
  it('preserves vertex elevations but leaves interpolated samples unelevated', () => {
    const profile = routeProfilePoints([{ lat: 0, lon: 0, elevation: 100 }, { lat: 0, lon: 1 }], 1000);
    expect(profile[0].elevation).toBe(100);
    expect(profile[profile.length - 1].elevation).toBeUndefined();
    const interior = profile.slice(1, -1);
    expect(interior.every((p) => p.elevation === undefined)).toBe(true);
  });
});

describe('summarizeProfile', () => {
  it('accumulates gain and loss sample-to-sample', () => {
    const summary = summarizeProfile([
      { lat: 0, lon: 0, elevation: 100 },
      { lat: 0, lon: 0.001, elevation: 300 },
      { lat: 0, lon: 0.002, elevation: 150 },
    ]);
    expect(summary.gain).toBeCloseTo(200, 6);
    expect(summary.loss).toBeCloseTo(150, 6);
    expect(summary.min).toBe(100);
    expect(summary.max).toBe(300);
  });
  it('reports the steepest segment angle', () => {
    // 100 m climb over ~111 m horizontal ≈ 42°
    const summary = summarizeProfile([
      { lat: 0, lon: 0, elevation: 100 },
      { lat: 0, lon: 0.001, elevation: 200 },
    ]);
    expect(summary.maxSlope).toBeCloseTo(41.921, 1);
  });
  it('returns an empty summary when there are fewer than two known elevations', () => {
    expect(summarizeProfile([{ lat: 0, lon: 0, elevation: 100 }])).toEqual({});
    expect(summarizeProfile([{ lat: 0, lon: 0 }])).toEqual({});
  });
});

describe('segmentSlopeDegrees', () => {
  it('ignores missing elevations', () => {
    expect(segmentSlopeDegrees({ lat: 0, lon: 0 }, { lat: 0, lon: 1 })).toBeUndefined();
  });
  it('ignores duplicated vertices', () => {
    expect(segmentSlopeDegrees({ lat: 0, lon: 0, elevation: 5 }, { lat: 0, lon: 0, elevation: 10 })).toBeUndefined();
  });
});