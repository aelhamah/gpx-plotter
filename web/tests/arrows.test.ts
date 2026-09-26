import { describe, expect, it, vi } from 'vitest';
import { addArrowImages, arrowIconId, ARROW_LAYER, ARROW_SPACING_PX, routeArrowsGeoJSON } from '../src/arrows';
import { ROUTE_COLORS } from '../src/colors';
import type { Route } from '../src/gpx';

/** ~1.1 km per segment, so arrows survive at any sane zoom. */
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

  it('paints each arrow in its own route color', () => {
    const data = routeArrowsGeoJSON([route(1, [TALL_SEGMENT, LONG_SEGMENT]), route(2, [TALL_SEGMENT, LONG_SEGMENT], { color: '#16a34a' })], 2, 14);
    expect(data.features.map((feature) => feature.properties?.color)).toEqual(['#e11d48', '#16a34a']);
    expect(data.features.map((feature) => feature.properties?.icon)).toEqual([arrowIconId('#e11d48'), arrowIconId('#16a34a')]);
  });
});

describe('arrowIconId', () => {
  it('gives every color its own icon and is stable across calls', () => {
    expect(arrowIconId('#e11d48')).toBe(arrowIconId('#e11d48'));
    expect(arrowIconId('#e11d48')).not.toBe(arrowIconId('#16a34a'));
    expect(new Set(ROUTE_COLORS.map(arrowIconId)).size).toBe(ROUTE_COLORS.length);
  });
});

describe('addArrowImages', () => {
  /** Node has no canvas, so stand in a 2d context that records what was drawn. */
  function stubCanvas() {
    const drawn: { fillStyle: string; firstPoint: [number, number] }[] = [];
    vi.stubGlobal('document', {
      createElement: () => ({
        width: 0,
        height: 0,
        getContext: () => {
          const state = { fillStyle: '', firstPoint: [0, 0] as [number, number] };
          return {
            set fillStyle(value: string) { state.fillStyle = value; },
            get fillStyle() { return state.fillStyle; },
            translate: () => {},
            beginPath: () => {},
            moveTo: (x: number, y: number) => { state.firstPoint = [x, y]; },
            lineTo: () => {},
            closePath: () => {},
            fill: () => drawn.push({ ...state }),
            stroke: () => {},
            getImageData: (_x: number, _y: number, w: number, h: number) => ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }),
          };
        },
      }),
    });
    return drawn;
  }

  function host() {
    const images = new Map<string, ImageData>();
    return { images, map: { hasImage: (id: string) => images.has(id), addImage: (id: string, image: ImageData) => void images.set(id, image) } };
  }

  it('registers one icon per palette color, filled with that color', () => {
    const drawn = stubCanvas();
    const { map, images } = host();
    addArrowImages(map);
    expect([...images.keys()]).toEqual(ROUTE_COLORS.map(arrowIconId));
    expect(drawn.map((d) => d.fillStyle)).toEqual(ROUTE_COLORS);
    vi.unstubAllGlobals();
  });

  it('adds a color outside the palette and leaves existing icons alone', () => {
    stubCanvas();
    const { map, images } = host();
    addArrowImages(map);
    const before = images.get(arrowIconId(ROUTE_COLORS[0]));
    addArrowImages(map, ['#123456', ROUTE_COLORS[0]]);
    expect(images.has(arrowIconId('#123456'))).toBe(true);
    expect(images.get(arrowIconId(ROUTE_COLORS[0]))).toBe(before);
    vi.unstubAllGlobals();
  });

  it('draws the chevron pointing north, so icon-rotate 0 means north', () => {
    const drawn = stubCanvas();
    addArrowImages(host().map, ['#e11d48']);
    // The first vertex sits above the icon's center: `icon-rotate` renders an
    // icon as authored at 0, and bearings are degrees clockwise from north.
    expect(drawn[0].firstPoint[1]).toBeLessThan(0);
    vi.unstubAllGlobals();
  });
});

describe('ARROW_LAYER', () => {
  it('picks the icon per feature and rotates it by the bearing', () => {
    expect(ARROW_LAYER.layout['icon-image']).toEqual(['get', 'icon']);
    expect(ARROW_LAYER.layout['icon-rotate']).toEqual(['get', 'bearing']);
  });
});
