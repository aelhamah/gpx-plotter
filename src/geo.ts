import type { RoutePoint } from './gpx';

const EARTH_RADIUS_M = 6371008.8;

export function haversineMeters(a: RoutePoint, b: RoutePoint): number {
  const lat1 = a.lat * Math.PI / 180;
  const lat2 = b.lat * Math.PI / 180;
  const dLat = (b.lat - a.lat) * Math.PI / 180;
  const dLon = (b.lon - a.lon) * Math.PI / 180;
  const sinLat = Math.sin(dLat / 2);
  const sinLon = Math.sin(dLon / 2);
  const h = sinLat * sinLat + Math.cos(lat1) * Math.cos(lat2) * sinLon * sinLon;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

export function routeDistanceMeters(points: RoutePoint[]): number {
  let total = 0;
  for (let i = 1; i < points.length; i++) total += haversineMeters(points[i - 1], points[i]);
  return total;
}

export function elevationStats(points: RoutePoint[]) {
  const valid = points.filter((p): p is RoutePoint & { elevation: number } => Number.isFinite(p.elevation));
  if (!valid.length) return { gain: undefined, loss: undefined, min: undefined, max: undefined };

  let gain = 0;
  let loss = 0;
  for (let i = 1; i < valid.length; i++) {
    const delta = valid[i].elevation - valid[i - 1].elevation;
    if (delta > 0) gain += delta;
    else if (delta < 0) loss += -delta;
  }
  return {
    gain,
    loss,
    min: Math.min(...valid.map((p) => p.elevation)),
    max: Math.max(...valid.map((p) => p.elevation)),
  };
}

/** Absolute terrain angle of each route segment, in degrees. */
export function segmentSlopeDegrees(a: RoutePoint, b: RoutePoint): number | undefined {
  if (!Number.isFinite(a.elevation) || !Number.isFinite(b.elevation)) return undefined;
  const horizontal = haversineMeters(a, b);
  if (horizontal < 0.01) return undefined;
  return Math.atan2(Math.abs((b.elevation as number) - (a.elevation as number)), horizontal) * 180 / Math.PI;
}

export function metersToMiles(m: number) { return m / 1609.344; }
export function metersToFeet(m: number) { return m * 3.280839895; }
