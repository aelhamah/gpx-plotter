import type { Feature, FeatureCollection, Point } from 'geojson';
import type { LayerSpecification } from 'maplibre-gl';
import type { Route } from './gpx';
import { segmentArrows } from './segments';

export const ARROW_ICON_ID = 'route-arrow';

/** Segments that pack closer together than this on screen get no arrow. */
export const ARROW_SPACING_PX = 64;

/** Icon is drawn at 2× and shown at `icon-size` 0.45–0.6, so it stays crisp when zoomed in. */
export const ARROW_ICON_PIXELS = 44;

/** White chevron outlined in the route-casing dark, pointing east at rotation 0. */
export function arrowIconImage(): ImageData {
  const canvas = document.createElement('canvas');
  canvas.width = ARROW_ICON_PIXELS;
  canvas.height = ARROW_ICON_PIXELS;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('2d canvas context unavailable');
  ctx.translate(ARROW_ICON_PIXELS / 2, ARROW_ICON_PIXELS / 2);
  ctx.beginPath();
  ctx.moveTo(15, 0);
  ctx.lineTo(-11, -14);
  ctx.lineTo(-4, 0);
  ctx.lineTo(-11, 14);
  ctx.closePath();
  ctx.fillStyle = '#ffffff';
  ctx.strokeStyle = '#0f172a';
  ctx.lineWidth = 2;
  ctx.lineJoin = 'round';
  ctx.fill();
  ctx.stroke();
  return ctx.getImageData(0, 0, ARROW_ICON_PIXELS, ARROW_ICON_PIXELS);
}

/**
 * One arrow per route segment, pointing the way the route travels, so the
 * direction of a route reads on the map even where two traces overlap. The
 * active route is emitted last so its arrows land on top of the other routes'.
 */
export function routeArrowsGeoJSON(routes: Route[], selectedRouteId: number | null, zoom: number): FeatureCollection<Point> {
  const visible = routes.filter((route) => route.visible !== false && route.points.length >= 2);
  const active = visible.filter((route) => route.id === selectedRouteId);
  const features: Feature<Point>[] = [];
  for (const route of [...visible.filter((route) => route.id !== selectedRouteId), ...active]) {
    for (const arrow of segmentArrows(route.points, ARROW_SPACING_PX, zoom)) {
      features.push({
        type: 'Feature',
        properties: { bearing: arrow.bearing, active: route.id === selectedRouteId, index: arrow.index },
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
 * traces run close together.
 */
export const ARROW_LAYER: LayerSpecification = {
  id: 'route-arrows',
  type: 'symbol',
  source: 'route-arrows',
  layout: {
    'icon-image': ARROW_ICON_ID,
    'icon-size': ['case', ['get', 'active'], 0.6, 0.45],
    'icon-rotate': ['get', 'bearing'],
    'icon-rotation-alignment': 'map',
    'icon-pitch-alignment': 'map',
    'icon-allow-overlap': true,
    'icon-ignore-placement': true,
  },
  paint: { 'icon-opacity': ['case', ['get', 'active'], 1, 0.65] },
};
