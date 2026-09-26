import { haversineMeters, inverseMercator, mercatorX, mercatorY } from './geo';
import type { RoutePoint } from './gpx';

const EQUATOR_METERS_PER_PIXEL = 156543.03392804097;

/** Ground resolution of the Web Mercator plane, in meters per screen pixel. */
export function metersPerPixel(zoom: number, lat: number): number {
  return (EQUATOR_METERS_PER_PIXEL * Math.cos((lat * Math.PI) / 180)) / 2 ** zoom;
}

/** Difference between two points in Mercator space, wrapped across the antimeridian. */
function mercatorDelta(a: RoutePoint, b: RoutePoint): { dx: number; dy: number } {
  const ax = mercatorX(a.lon);
  let bx = mercatorX(b.lon);
  if (bx - ax > 0.5) bx -= 1;
  else if (bx - ax < -0.5) bx += 1;
  return { dx: bx - ax, dy: mercatorY(b.lat) - mercatorY(a.lat) };
}

/**
 * Heading of the drawn segment a→b in degrees clockwise from map north. Routes
 * are drawn as straight lines in Web Mercator, so it is the Mercator slope —
 * not the great-circle bearing — that a rotated arrow has to match.
 */
export function segmentBearingDegrees(a: RoutePoint, b: RoutePoint): number {
  const { dx, dy } = mercatorDelta(a, b);
  if (dx === 0 && dy === 0) return 0;
  return (Math.atan2(dx, -dy) * 180 / Math.PI + 360) % 360;
}

/** Midpoint of the drawn (Mercator-straight) segment a→b. */
export function segmentMidpoint(a: RoutePoint, b: RoutePoint): RoutePoint {
  const ax = mercatorX(a.lon);
  const ay = mercatorY(a.lat);
  const { dx, dy } = mercatorDelta(a, b);
  const { lat, lng } = inverseMercator(ay + dy / 2, ax + dx / 2);
  return { lat, lon: lng };
}

export interface SegmentArrow {
  /** Index of the segment: it runs from `points[index]` to `points[index + 1]`. */
  index: number;
  lat: number;
  lon: number;
  /** Screen heading of the segment, degrees clockwise from map north. */
  bearing: number;
  /** Ground length of the segment in meters. */
  meters: number;
}

/**
 * One arrow per segment, at the segment's midpoint, pointing from a to b.
 * Repeated points have no direction and are skipped, as are segments shorter than
 * `minPixels` at the current `zoom`, so a densely sampled track does not smear
 * into a solid band of arrows.
 */
export function segmentArrows(points: RoutePoint[], minPixels: number, zoom: number): SegmentArrow[] {
  const arrows: SegmentArrow[] = [];
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1];
    const b = points[i];
    const mid = segmentMidpoint(a, b);
    const meters = haversineMeters(a, b);
    if (meters === 0) continue;
    if (meters < minPixels * metersPerPixel(zoom, mid.lat)) continue;
    arrows.push({ index: i - 1, lat: mid.lat, lon: mid.lon, bearing: segmentBearingDegrees(a, b), meters });
  }
  return arrows;
}
