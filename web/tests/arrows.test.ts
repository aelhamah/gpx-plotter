import { describe, expect, it } from 'vitest';
import { ARROW_ICON_ID, ARROW_SPACING_PX, routeArrowsGeoJSON } from '../src/arrows';
import type { Route } from '../src/gpx';

/** ~1.1 km east per segment, so arrows survive at any sane zoom. */
const LONG_SEGMENT = { lat: 39.5, lon: 0.01 };
const TALL_SEGMENT = { lat: 39.51, lon: 0 };

function route(id: number, points: { lat: number; lon: number }[], extra: Partial<Route> = {}): Route {
  return { id, name: `Route ${id}`, points, color: '#e11d48', ...extra };
}

describe('routeArrowsGeoJSON', () => {
  it('emits one point per segment with its bearing', () => {
    // Southeast leg, then due north: one arrow each, pointing the way the route goes.
    const data = routeArrowsGeoJSON([route(1, [TALL_SEGMENT, LONG_SEGMENT, { lat: 39.51, lon: 0.01 }])], 1, 14);
    expect(data.features).toHaveLength(2);
    expect(data.features.map((feature) => feature.properties?.index)).toEqual([0, 1]);
    expect(data.features.map((feature) => Math.round(feature.properties?.bearing as number))).toEqual([142, 0]);
    expect(data.features.every((feature) => feature.properties?.active === true)).toBe(true);
  });

  it('leaves out hidden routes and single-point routes', () => {
    const data = routeArrowsGeoJSON([
      route(1, [TALL_SEGMENT, LONG_SEGMENT], { visible: false }),
      route(2, [TALL_SEGMENT]),
    ], 1, 14);
    expect(data.features).toEqual([]);
  });

  it('puts the active route last so its arrows draw on top', () => {
    const data = routeArrowsGeoJSON([route(1, [TALL_SEGMENT, LONG_SEGMENT]), route(2, [TALL_SEGMENT, LONG_SEGMENT])], 2, 14);
    expect(data.features).toHaveLength(2);
    expect(data.features.map((feature) => feature.properties?.active)).toEqual([false, true]);
  });

  it('thins out segments that are too close together on screen', () => {
    const data = routeArrowsGeoJSON([route(1, [TALL_SEGMENT, { lat: 39.5, lon: 0.0002 }])], 1, 10);
    expect(data.features).toEqual([]);
    expect(ARROW_SPACING_PX).toBeGreaterThan(0);
  });

  it('references the icon the layer asks for', () => {
    expect(ARROW_ICON_ID).toBe('route-arrow');
  });
});
