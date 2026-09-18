import { describe, expect, it } from 'vitest';
import { MERGE_OVERLAP_METERS, mergeRoutePoints } from '../src/merge';
import { routeDistanceMeters } from '../src/geo';
import type { RoutePoint } from '../src/gpx';

/** Build collinear points running east from a start longitude at meter offsets. */
function positions(meters: number[], lat = 39): RoutePoint[] {
  const lonPerMeter = 1 / (111320 * Math.cos((lat * Math.PI) / 180));
  return meters.map((m) => ({ lat, lon: m * lonPerMeter }));
}

describe('mergeRoutePoints', () => {
  it('concatenates two routes that are apart, keeping their order', () => {
    const a = positions([0, 100, 200, 300, 400]);
    const b = positions([600, 700, 800]);
    const merged = mergeRoutePoints(a, b);
    expect(merged).toEqual([...a, ...b]);
    expect(Math.abs(routeDistanceMeters(merged) - (400 + 200 + 200))).toBeLessThan(1);
  });

  it('reverses one route so the merged trace connects the nearest endpoints', () => {
    const a = positions([0, 100, 200, 300, 400]);
    const b = positions([800, 700, 600]);
    const merged = mergeRoutePoints(a, b);
    expect(merged[0]).toBe(a[0]);
    expect(merged.at(-1)).toEqual(positions([800])[0]);
    expect(Math.abs(routeDistanceMeters(merged) - (400 + 200 + 200))).toBeLessThan(1);
  });

  it('trims a same-direction seam that duplicates ground within 10 m', () => {
    const a = positions([0, 10, 20, 30, 40, 50, 60, 70, 80]);
    const b = positions([70, 90, 110]);
    const merged = mergeRoutePoints(a, b);
    expect(merged).toEqual([...a, ...positions([90, 110])]);
    expect(Math.abs(routeDistanceMeters(merged) - (80 + 10 + 20))).toBeLessThan(1);
  });

  it('drops only the duplicated head of the second route at the joint', () => {
    const a = positions([0, 10, 20, 30, 40]);
    const b = positions([42, 46, 50]);
    const merged = mergeRoutePoints(a, b);
    expect(merged).toEqual([...a, ...positions([46, 50])]);
    expect(Math.abs(routeDistanceMeters(merged) - 50)).toBeLessThan(1);
  });

  it('keeps a return seam (opposite travel direction) intact without trimming', () => {
    const a = positions([0, 10, 20, 30, 40]);
    const b = positions([30, 20, 10, 5]);
    const merged = mergeRoutePoints(a, b);
    expect(merged.length).toBe(a.length + b.length);
    expect(Math.abs(routeDistanceMeters(merged) - 70)).toBeLessThan(1);
  });

  it('preserves a fully duplicated return leg instead of truncating it', () => {
    const a = positions([0, 10, 20, 30, 40]);
    const b = positions([40, 30, 20, 10, 0]);
    const merged = mergeRoutePoints(a, b);
    expect(merged).toEqual([...a, ...b]);
  });

  it('handles empty and single-point inputs', () => {
    const a = positions([0, 10, 20]);
    const b = positions([5, 50, 100]);
    expect(mergeRoutePoints([], b)).toEqual(b);
    expect(mergeRoutePoints(a, [])).toEqual(a);
    expect(mergeRoutePoints([positions([0])[0]], b).length).toBe(4);
  });

  it('exposes the 10 m overlap tolerance used for seam reduction', () => {
    expect(MERGE_OVERLAP_METERS).toBe(10);
  });
});