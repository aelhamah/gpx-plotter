import { describe, expect, it, vi } from 'vitest';
import { addArrowImages, arrowIconId, ARROW_KEYLINE_PX, ARROW_LAYER, ARROW_MIN_SCALE, ARROW_SPACING_PX, routeArrowsGeoJSON } from '../src/arrows';
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
    const drawn: {
      fillStyle: string;
      firstPoint: [number, number];
      points: [number, number][];
      calls: string[];
      strokeStyle: string;
      lineWidth: number;
    }[] = [];
    vi.stubGlobal('document', {
      createElement: () => ({
        width: 0,
        height: 0,
        getContext: () => {
          const state = {
            fillStyle: '',
            strokeStyle: '',
            lineWidth: 0,
            firstPoint: [0, 0] as [number, number],
            points: [] as [number, number][],
            calls: [] as string[],
          };
          const record = (call: string) => () => {
            state.calls.push(call);
            if (call === 'fill' || call === 'stroke') {
              // Snapshot, not spread: `calls` and `points` are arrays, and a
              // spread would share them with later records.
              drawn.push({ ...state, calls: [...state.calls], points: [...state.points] });
            }
          };
          return {
            set fillStyle(value: string) { state.fillStyle = value; },
            get fillStyle() { return state.fillStyle; },
            set strokeStyle(value: string) { state.strokeStyle = value; },
            get strokeStyle() { return state.strokeStyle; },
            set lineWidth(value: number) { state.lineWidth = value; },
            get lineWidth() { return state.lineWidth; },
            translate: () => {},
            beginPath: record('beginPath'),
            moveTo: (x: number, y: number) => { state.firstPoint = [x, y]; state.points.push([x, y]); },
            lineTo: (x: number, y: number) => state.points.push([x, y]),
            closePath: () => {},
            fill: record('fill'),
            stroke: record('stroke'),
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

  /** The icon is stroked as well as filled, and only the fill record carries the
   * whole outline, so work from that one. */
  function fills(drawn: ReturnType<typeof stubCanvas>): ReturnType<typeof stubCanvas> {
    return drawn.filter((entry) => entry.calls.includes('fill'));
  }

  /** On-screen widths of the arrowhead and the shaft, measured from the outline
   * the icon was drawn with. The arrow is drawn for the smallest `icon-size` the
   * layer uses, so that is the scale to measure it at. */
  function widths(shape: ReturnType<typeof stubCanvas>[number]): { shaft: number; head: number } {
    const half = [...new Set(shape.points.map(([x]) => Math.abs(x)))].sort((a, b) => b - a);
    return { head: round2(half[0] * 2 * ARROW_MIN_SCALE), shaft: round2(half[1] * 2 * ARROW_MIN_SCALE) };
  }

  function round2(n: number): number {
    return Math.round(n * 100) / 100;
  }

  it('registers one icon per palette color, filled with that color', () => {
    const drawn = stubCanvas();
    const { map, images } = host();
    addArrowImages(map);
    expect([...images.keys()]).toEqual(ROUTE_COLORS.map(arrowIconId));
    expect(fills(drawn).map((d) => d.fillStyle)).toEqual(ROUTE_COLORS);
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

  it('draws the arrow pointing north, so icon-rotate 0 means north', () => {
    const drawn = stubCanvas();
    addArrowImages(host().map, ['#e11d48']);
    // The first vertex sits above the icon's center: `icon-rotate` renders an
    // icon as authored at 0, and bearings are degrees clockwise from north.
    expect(fills(drawn)[0].firstPoint[1]).toBeLessThan(0);
    vi.unstubAllGlobals();
  });

  it('keys the arrow in white, stroking before the fill so the band lands outside', () => {
    const drawn = stubCanvas();
    addArrowImages(host().map, ['#e11d48']);
    const shape = fills(drawn)[0];
    expect(shape.strokeStyle).toBe('#ffffff');
    // Stroke-then-fill is what keeps the white band on the outside of the shape
    // instead of eating into the colored core.
    expect(shape.calls.indexOf('stroke')).toBeLessThan(shape.calls.indexOf('fill'));
    vi.unstubAllGlobals();
  });

  it('sizes the shaft and its keyline to the route line it sits on', () => {
    const drawn = stubCanvas();
    addArrowImages(host().map, ['#e11d48']);
    const { shaft, head } = widths(fills(drawn)[0]);
    // Routes are a 4px line inside an 8px white casing. The colored shaft has to
    // cover the 4px line, and the keyline has to carry the arrow's outer edge out
    // to the casing's own 8px — inside that and the arrow floats in the line's
    // halo instead of blending with it.
    expect(shaft).toBeGreaterThanOrEqual(4);
    expect(round2(shaft + ARROW_KEYLINE_PX * 2)).toBe(8);
    // And the head still flares out past the casing, so the direction reads.
    expect(head).toBeGreaterThan(4);
    vi.unstubAllGlobals();
  });
});

describe('ARROW_LAYER', () => {
  it('picks the icon per feature and rotates it by the bearing', () => {
    expect(ARROW_LAYER.layout['icon-image']).toEqual(['get', 'icon']);
    expect(ARROW_LAYER.layout['icon-rotate']).toEqual(['get', 'bearing']);
  });
});
