import { describe, expect, it } from 'vitest';
import { dedupeTrailLines, routeAlongTrails, TRAIL_JOIN_METERS } from '../src/trailGraph';

const line = (...points: [number, number][]) => points.map(([lon, lat]) => ({ lon, lat }));

describe('dedupeTrailLines', () => {
  it('drops identical polylines but keeps distinct ones', () => {
    const a = line([0, 0], [0.001, 0]);
    const same = line([0, 0], [0.001, 0]);
    const other = line([0, 0], [0, 0.001]);
    expect(dedupeTrailLines([a, same, other])).toEqual([a, other]);
  });

  it('drops degenerate single-point lines', () => {
    expect(dedupeTrailLines([line([0, 0]), line([0, 0], [0.001, 0])])).toHaveLength(1);
  });
});

describe('routeAlongTrails', () => {
  it('routes along a connected trail through its vertices', () => {
    const corner = { lon: 0.001, lat: 0 };
    const trails = [line([0, 0], [0.001, 0], [0.001, 0.001])];
    const path = routeAlongTrails(trails, { lon: 0, lat: 0 }, { lon: 0.001, lat: 0.001 });
    expect(path).not.toBeNull();
    expect(path!.length).toBe(3);
    expect(path![1].lon).toBeCloseTo(corner.lon, 6);
    expect(path![1].lat).toBeCloseTo(corner.lat, 6);
  });

  it('bridges a split way whose loose ends are within the join distance', () => {
    const gap = TRAIL_JOIN_METERS / 2 / 110574; // half the join distance in degrees latitude
    const first = line([0, 0], [0, 0.001]);
    const second = line([0, 0.001 + gap], [0, 0.002]);
    const path = routeAlongTrails([first, second], { lon: 0, lat: 0 }, { lon: 0, lat: 0.002 });
    expect(path).not.toBeNull();
    expect(path!.length).toBeGreaterThanOrEqual(4);
  });

  it('does not bridge loose ends beyond the join distance', () => {
    const gap = (TRAIL_JOIN_METERS * 5) / 110574;
    const first = line([0, 0], [0, 0.001]);
    const second = line([0, 0.001 + gap], [0, 0.002]);
    expect(routeAlongTrails([first, second], { lon: 0, lat: 0 }, { lon: 0, lat: 0.002 })).toBeNull();
  });

  it('rejects a path whose detour exceeds the limit', () => {
    // Two parallel trails whose far ends connect (~11 m apart), but whose near
    // ends are only ~11 m apart yet not directly linked: the network path is
    // ~2 km, so the detour guard must refuse it.
    const trails = [line([-0.01, 0], [0, 0], [0.01, 0]), line([-0.01, 0.0001], [0, 0.0001], [0.01, 0.0001])];
    const path = routeAlongTrails(trails, { lon: 0, lat: 0 }, { lon: 0, lat: 0.0001 });
    expect(path).toBeNull();
  });

  it('returns null with no trails at all', () => {
    expect(routeAlongTrails([], { lon: 0, lat: 0 }, { lon: 0.001, lat: 0 })).toBeNull();
  });
});
