import { describe, it, expect } from 'vitest';
import {
  haversineMeters,
  mercatorX,
  mercatorY,
  inverseMercator,
  routeProfilePoints,
  summarizeProfile,
  segmentSlopeDegrees,
  profileAxisStep,
  nearestProfileSample,
  colorToAlpha,
  metersToKm,
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

describe('profileAxisStep', () => {
  it('returns 0 for a zero-length route', () => {
    expect(profileAxisStep(0)).toBe(0);
  });
  it('picks a nice even spacing in 1/2/5 decades', () => {
    for (const [total, expected] of [
      [3000, 500],   // 3 km → 6 divisions of 500 m
      [10000, 2000], // 10 km → 5 divisions of 2 km
      [40000, 10000], // 40 km → 4 divisions of 10 km
      [500, 100],    // 500 m → 5 divisions of 100 m
      [75, 20],      // 75 m → ~4 divisions of 20 m
    ] as [number, number][]) {
      expect(profileAxisStep(total), `total=${total}`).toBe(expected);
    }
  });
  it('always fits into the total (so ticks exist only inside the route)', () => {
    for (const total of [800, 1600, 5000, 12000, 900000]) {
      expect(profileAxisStep(total)).toBeLessThanOrEqual(total);
    }
  });
});

describe('nearestProfileSample', () => {
  it('snaps to the closest cumulative distance', () => {
    const cumulative = [0, 1000, 2000, 3000];
    expect(nearestProfileSample(cumulative, 0)).toBe(0);
    expect(nearestProfileSample(cumulative, 999)).toBe(1);
    expect(nearestProfileSample(cumulative, 2499)).toBe(2);
    expect(nearestProfileSample(cumulative, 4000)).toBe(3);
  });
});

describe('colorToAlpha', () => {
  it('converts a hex color to an rgba string', () => {
    expect(colorToAlpha('#22c55e', 0.5)).toBe('rgba(34, 197, 94, 0.5)');
    expect(colorToAlpha('#111827', 1)).toBe('rgba(17, 24, 39, 1)');
  });
});

describe('metersToKm', () => {
  it('converts meters to kilometers', () => {
    expect(metersToKm(1000)).toBeCloseTo(1, 9);
    expect(metersToKm(3218.688)).toBeCloseTo(3.219, 2);
  });
});