import { describe, it, expect } from 'vitest';
import {
  haversineMeters,
  mercatorX,
  mercatorY,
  inverseMercator,
  routeProfilePoints,
  blendTerrainElevations,
  interpolateProfileElevations,
  profileNeedsTerrain,
  terrainSamplesNeeded,
  summarizeProfile,
  segmentSlopeDegrees,
  profileAxisStep,
  nearestProfileSample,
  colorToAlpha,
  metersToKm,
} from '../src/geo';
import type { RoutePoint } from '../src/gpx';

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
describe('profileNeedsTerrain', () => {
  it('is false once the track carries any elevation of its own', () => {
    expect(profileNeedsTerrain([{ lat: 0, lon: 0, elevation: 3000 }, { lat: 0, lon: 0 }])).toBe(false);
  });
  it('is true when the track recorded nothing usable', () => {
    expect(profileNeedsTerrain([{ lat: 0, lon: 0 }, { lat: 0, lon: 0 }])).toBe(true);
    expect(profileNeedsTerrain([{ lat: 0, lon: 0, elevation: NaN }])).toBe(true);
    expect(profileNeedsTerrain([])).toBe(true);
  });
});

describe('interpolateProfileElevations', () => {
  it('fills a gap by interpolating between the two known values', () => {
    const filled = interpolateProfileElevations([
      { lat: 0, lon: 0, elevation: 100 },
      { lat: 0, lon: 0 },
      { lat: 0, lon: 0 },
      { lat: 0, lon: 0, elevation: 400 },
    ]);
    expect(filled.map((p) => p.elevation)).toEqual([100, 200, 300, 400]);
  });

  it('never overwrites an elevation the track recorded', () => {
    const filled = interpolateProfileElevations([
      { lat: 0, lon: 0, elevation: 2960 },
      { lat: 0, lon: 0 },
      { lat: 0, lon: 0, elevation: 3410 },
    ]);
    expect(filled[0].elevation).toBe(2960);
    expect(filled[2].elevation).toBe(3410);
  });

  it('holds leading and trailing runs flat rather than extrapolating', () => {
    const filled = interpolateProfileElevations([
      { lat: 0, lon: 0 },
      { lat: 0, lon: 0, elevation: 500 },
      { lat: 0, lon: 0 },
    ]);
    expect(filled.map((p) => p.elevation)).toEqual([500, 500, 500]);
  });

  it('leaves a profile with nothing to work from alone, for the DEM to fill', () => {
    const profile = [{ lat: 0, lon: 0 }, { lat: 0, lon: 0 }];
    expect(interpolateProfileElevations(profile).map((p) => p.elevation)).toEqual([undefined, undefined]);
  });

  // The defect: filling every gap from the DEM put a dip at each vertex, because
  // the terrain and the track disagree by hundreds of metres on a hand-drawn
  // route. Interpolating cannot produce a sample below both its neighbours.
  it('produces no dip below both neighbours', () => {
    const profile: RoutePoint[] = [{ lat: 0, lon: 0, elevation: 3000 }];
    for (let step = 1; step <= 4; step++) {
      profile.push({ lat: 0, lon: 0, elevation: 3000 + step * 100 });
      for (let i = 0; i < 9; i++) profile.push({ lat: 0, lon: 0 });
    }
    const elevations = interpolateProfileElevations(profile).map((p) => p.elevation as number);
    for (let i = 1; i < elevations.length - 1; i++) {
      expect(elevations[i] >= Math.min(elevations[i - 1], elevations[i + 1])).toBe(true);
    }
    expect(elevations[elevations.length - 1]).toBe(3400);
  });

  it('keeps the sample count, since distances are indexed against it', () => {
    const profile = [
      { lat: 0, lon: 0 },
      { lat: 0, lon: 0, elevation: 100 },
      { lat: 0, lon: 0 },
    ];
    expect(interpolateProfileElevations(profile)).toHaveLength(3);
  });
});

describe('terrainSamplesNeeded', () => {
  it('asks for every gap and the samples that bound it', () => {
    expect(terrainSamplesNeeded([{ elevation: 100 }, {}, {}, {}, { elevation: 200 }])).toEqual([0, 1, 2, 3, 4]);
  });
  it('does not repeat a sample that bounds two runs', () => {
    expect(terrainSamplesNeeded([{ elevation: 100 }, {}, { elevation: 200 }, {}, { elevation: 300 }])).toEqual([0, 1, 2, 3, 4]);
  });
  it('asks for nothing when the track recorded every sample, as a dense fix does', () => {
    expect(terrainSamplesNeeded([{ elevation: 100 }, { elevation: 200 }])).toEqual([]);
  });
});

describe('blendTerrainElevations', () => {
  it('keeps the track\'s own elevations and the DEM\'s shape between them', () => {
    // A flat track across five samples, with a gully the track never recorded.
    const track = [{ elevation: 1000 }, {}, {}, {}, {}, { elevation: 1000 }];
    const blended = blendTerrainElevations([1000, 1000, 800, 800, 1000, 1000], track);
    expect(blended.map((p) => p.elevation)).toEqual([1000, 1000, 800, 800, 1000, 1000]);
  });

  it('puts the track above the DEM by the same amount at both ends of a gap', () => {
    // The track sits 100 m above the DEM at both bounding vertices, so the DEM\'s
    // shape between them is carried across 100 m rather than dropped.
    const track = [{ elevation: 1100 }, {}, {}, {}, { elevation: 1100 }];
    const blended = blendTerrainElevations([1000, 1000, 900, 1000, 1000], track);
    expect(blended.map((p) => p.elevation)).toEqual([1100, 1100, 1000, 1100, 1100]);
  });

  it('uses the DEM as it stands for a track with no elevation at all', () => {
    const blended = blendTerrainElevations([100, 200, 300], [{}, {}, {}]);
    expect(blended.map((p) => p.elevation)).toEqual([100, 200, 300]);
  });

  it('falls back to the track\'s line where the DEM did not answer', () => {
    const track = [{ elevation: 100 }, {}, {}, { elevation: 400 }];
    const blended = blendTerrainElevations([100, undefined, undefined, 400], track);
    expect(blended.map((p) => p.elevation)).toEqual([100, 200, 300, 400]);
  });

  it('keeps the sample count, since distances are indexed against it', () => {
    expect(blendTerrainElevations([1, 2, 3], [{ elevation: 1 }, {}, {}])).toHaveLength(3);
  });
});
