import { describe, it, expect } from 'vitest';
import { downsamplePoints } from '../src/simplify';

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
