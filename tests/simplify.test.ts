import { describe, it, expect } from 'vitest';
import { defaultPointBudget, downsamplePoints } from '../src/simplify';

const line = (count: number) => Array.from({ length: count }, (_, i) => ({ lat: 40 + i * 0.0001, lon: -105 + i * 0.0001 }));

describe('downsamplePoints', () => {
  it('returns a copy untouched when the target is at or above the point count', () => {
    const points = line(10);
    const result = downsamplePoints(points, 10);
    expect(result).toHaveLength(10);
    expect(result).not.toBe(points);
    expect(downsamplePoints(points, 50)).toEqual(points);
  });

  it('never exceeds the target and keeps the first and last points', () => {
    const points = line(10000);
    const result = downsamplePoints(points, 500);
    expect(result.length).toBeLessThanOrEqual(500);
    expect(result[0]).toEqual(points[0]);
    expect(result[result.length - 1]).toEqual(points[points.length - 1]);
  });

  it('stays close to the target for a uniform track', () => {
    const result = downsamplePoints(line(5000), 1000);
    expect(result.length).toBeGreaterThan(700);
    expect(result.length).toBeLessThanOrEqual(1000);
  });

  it('thins duplicate coordinates without dropping endpoints', () => {
    const points = Array.from({ length: 100 }, () => ({ lat: 1, lon: 2 }));
    const result = downsamplePoints(points, 25);
    expect(result.length).toBeLessThanOrEqual(25);
    expect(result[0]).toEqual({ lat: 1, lon: 2 });
    expect(result[result.length - 1]).toEqual({ lat: 1, lon: 2 });
  });

  it('handles the trivial cases', () => {
    expect(downsamplePoints([], 100)).toEqual([]);
    expect(downsamplePoints([{ lat: 0, lon: 0 }], 100)).toHaveLength(1);
    expect(downsamplePoints(line(10), 1)).toHaveLength(10);
  });
});

describe('defaultPointBudget', () => {
  it('scales the budget with distance at roughly one point per 10 m', () => {
    expect(defaultPointBudget(7110, 13360)).toBe(711);
    expect(defaultPointBudget(20000, 50000)).toBe(2000);
  });

  it('never suggests more points than the track has', () => {
    expect(defaultPointBudget(50000, 800)).toBe(800);
  });

  it('falls back to the point count when there is no usable distance', () => {
    expect(defaultPointBudget(0, 1234)).toBe(1234);
    expect(defaultPointBudget(Number.NaN, 1234)).toBe(1234);
    expect(defaultPointBudget(-5, 900)).toBe(900);
  });

  it('keeps a two-point floor', () => {
    expect(defaultPointBudget(3, 500)).toBe(2);
  });
});
