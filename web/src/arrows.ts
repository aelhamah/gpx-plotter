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

/**
 * One icon per route color, filled with that color.
 */
export function arrowIconId(color: string): string {
  return `${ARROW_ICON_PREFIX}${color}`;
}

/**
 * A chevron pointing **north** at rotation 0, because `icon-rotate` renders the
 * icon as authored at 0 and turns it clockwise from there — which is the same
 * direction bearings are measured in.
 *
 * It is just the route color, with no border of its own: the chevron sits on a
 * line of that same color, so a contrasting keyline only ever cut the line in
 * two. The shape carries the meaning — the point says which way the route goes,
 * and the notch lets the line show through so the chevron reads as part of it
 * rather than as a sticker on top. It is drawn a shade wider than the 4px line
 * so the flare past the line is visible at a glance.
 */
export function arrowIconImage(color: string): ImageData {
  const canvas = document.createElement('canvas');
  canvas.width = ARROW_ICON_PIXELS;
  canvas.height = ARROW_ICON_PIXELS;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('2d canvas context unavailable');
  ctx.translate(ARROW_ICON_PIXELS / 2, ARROW_ICON_PIXELS / 2);
  ctx.beginPath();
  ctx.moveTo(0, -14);
  ctx.lineTo(14, 7);
  ctx.lineTo(0, -2);
  ctx.lineTo(-14, 7);
  ctx.closePath();
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
 * are all drawn at full opacity and a translucent arrow would read as a
 * rendering glitch rather than as a quieter route.
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
