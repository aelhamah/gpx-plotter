import type { Feature, FeatureCollection, Point } from 'geojson';
import type { LayerSpecification } from 'maplibre-gl';
import { ROUTE_COLORS } from './colors';
import type { Route } from './gpx';
import { segmentArrows } from './segments';

export const ARROW_ICON_PREFIX = 'route-arrow-';

/** Segments that pack closer together than this on screen get no arrow. */
export const ARROW_SPACING_PX = 64;

/** Icon is drawn at 2× and shown at `icon-size` 0.45–0.6, so it stays crisp when zoomed in. */
export const ARROW_ICON_PIXELS = 44;

/** On-screen width of the white band down each side of the arrow, in CSS pixels. */
export const ARROW_KEYLINE_PX = 1.5;

/**
 * The smallest `icon-size` the layer uses, and therefore the scale the icon is
 * drawn for. Every dimension below is authored in on-screen pixels and divided
 * by this, because a stroke that looks right at full size all but disappears
 * once `icon-size` has scaled the icon down to 0.45 — and the keyline is the
 * whole reason the arrow reads against the line.
 */
export const ARROW_MIN_SCALE = 0.45;

const screen = (pixels: number) => pixels / ARROW_MIN_SCALE;

/** How far the tip reaches ahead of the segment's midpoint. */
const TIP = screen(7);
/** Half-width of the arrowhead, where it flares out of the shaft. */
const HEAD_HALF_WIDTH = screen(5);
/** Where the flare ends and the shaft begins, ahead of the midpoint. */
const HEAD_TRAILING = screen(1);
/**
 * Half-width of the shaft. A shade wider than the 4px route line so the fill
 * covers the line's own antialiased edge instead of fraying against it.
 */
const SHAFT_HALF_WIDTH = screen(2.5);
/** How far the shaft reaches behind the midpoint, over the line it continues. */
const TAIL = screen(5);
/**
 * Icon-space stroke width. Half of it lands under the fill, so the stroke is
 * twice the band that is meant to be visible.
 */
const KEYLINE = screen(ARROW_KEYLINE_PX * 2);

/**
 * One icon per route color, filled with that color and keyed in white so it
 * stays legible on top of the identically colored route line.
 */
export function arrowIconId(color: string): string {
  return `${ARROW_ICON_PREFIX}${color}`;
}

/**
 * A dart pointing **north** at rotation 0, because `icon-rotate` renders the
 * icon as authored at 0 and turns it clockwise from there — which is the same
 * direction bearings are measured in.
 *
 * Its proportions are borrowed from the route line it has to blend into: routes
 * are drawn as a 4px colored line inside an 8px white casing, so the shaft is
 * 5px of that same color and the 1.5px keyline on each side carries its outer
 * edge to 8px, exactly where the casing already is. The arrowhead then flares
 * out of that footprint. The result reads as the line swelling into an arrow
 * rather than as a marker sitting on top of it, which a plain chevron cannot do
 * — its hollow lets the line show through the notch, and keylining that notch
 * cuts the line in two.
 *
 * The keyline is stroked *before* the fill, so only its outer half survives and
 * the colored core stays crisp instead of being eaten from the inside.
 */
export function arrowIconImage(color: string): ImageData {
  const canvas = document.createElement('canvas');
  canvas.width = ARROW_ICON_PIXELS;
  canvas.height = ARROW_ICON_PIXELS;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('2d canvas context unavailable');
  ctx.translate(ARROW_ICON_PIXELS / 2, ARROW_ICON_PIXELS / 2);
  ctx.beginPath();
  ctx.moveTo(0, -TIP);
  ctx.lineTo(HEAD_HALF_WIDTH, -HEAD_TRAILING);
  ctx.lineTo(SHAFT_HALF_WIDTH, -HEAD_TRAILING);
  ctx.lineTo(SHAFT_HALF_WIDTH, TAIL);
  ctx.lineTo(-SHAFT_HALF_WIDTH, TAIL);
  ctx.lineTo(-SHAFT_HALF_WIDTH, -HEAD_TRAILING);
  ctx.lineTo(-HEAD_HALF_WIDTH, -HEAD_TRAILING);
  ctx.closePath();
  ctx.strokeStyle = '#ffffff';
  ctx.lineWidth = KEYLINE;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  ctx.stroke();
  ctx.fillStyle = color;
  ctx.fill();
  return ctx.getImageData(0, 0, ARROW_ICON_PIXELS, ARROW_ICON_PIXELS);
}

/** Registers an arrow per color, skipping the ones the style already has. */
export function addArrowImages(map: ArrowImageHost, colors: readonly string[] = ROUTE_COLORS): void {
  for (const color of colors) {
    const id = arrowIconId(color);
    if (!map.hasImage(id)) map.addImage(id, arrowIconImage(color));
  }
}

export interface ArrowImageHost {
  hasImage(id: string): boolean;
  addImage(id: string, image: ImageData): void;
}

/**
 * One arrow per segment, at the segment's midpoint, pointing from a to b, in
 * the route's own color so the direction reads even where two traces overlap.
 * The active route is emitted last so its arrows land on top of the other routes'.
 */
export function routeArrowsGeoJSON(routes: Route[], selectedRouteId: number | null, zoom: number): FeatureCollection<Point> {
  const visible = routes.filter((route) => route.visible !== false && route.points.length >= 2);
  const active = visible.filter((route) => route.id === selectedRouteId);
  const features: Feature<Point>[] = [];
  for (const route of [...visible.filter((route) => route.id !== selectedRouteId), ...active]) {
    for (const arrow of segmentArrows(route.points, ARROW_SPACING_PX, zoom)) {
      features.push({
        type: 'Feature',
        properties: {
          bearing: arrow.bearing,
          active: route.id === selectedRouteId,
          index: arrow.index,
          color: route.color,
          icon: arrowIconId(route.color),
        },
        geometry: { type: 'Point', coordinates: [arrow.lon, arrow.lat] },
      });
    }
  }
  return { type: 'FeatureCollection', features };
}

/**
 * Arrows render as canvas symbols, not DOM markers, so they stay glued to the
 * globe and the terrain. `icon-rotation-alignment: 'map'` turns the icon by the
 * segment's Mercator bearing; the overlap/ignore-placement pair keeps the arrows
 * from being culled by the symbol collider, which would drop arrows wherever
 * traces run close together. `icon-image` is per feature because each route color
 * needs its own pre-tinted arrow.
 *
 * The active route's arrows are larger; nothing dims them, because route lines
 * are all drawn at full opacity and a translucent arrow would show the casing
 * through its own keyline.
 */
export const ARROW_LAYER: LayerSpecification = {
  id: 'route-arrows',
  type: 'symbol',
  source: 'route-arrows',
  layout: {
    'icon-image': ['get', 'icon'],
    'icon-size': ['case', ['get', 'active'], 0.6, 0.45],
    'icon-rotate': ['get', 'bearing'],
    'icon-rotation-alignment': 'map',
    'icon-pitch-alignment': 'map',
    'icon-allow-overlap': true,
    'icon-ignore-placement': true,
  },
};
