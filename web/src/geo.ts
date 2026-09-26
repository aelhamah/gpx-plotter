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

export interface ProfileSummary {
  gain?: number;
  loss?: number;
  min?: number;
  max?: number;
  maxSlope?: number;
}

/**
 * Elevation statistics over a dense terrain profile (the output of
 * `routeProfilePoints` with elevations filled from the DEM). Accumulates gain
 * and loss sample-to-sample and tracks the steepest segment angle, so the
 * numbers reflect the terrain crossed *between* route vertices.
 */
export function summarizeProfile(profile: RoutePoint[]): ProfileSummary {
  const valid = profile.filter((p): p is RoutePoint & { elevation: number } => Number.isFinite(p.elevation));
  if (valid.length < 2) return {};
  let gain = 0;
  let loss = 0;
  let maxSlope: number | undefined;
  for (let i = 1; i < valid.length; i++) {
    const delta = valid[i].elevation - valid[i - 1].elevation;
    if (delta > 0) gain += delta;
    else if (delta < 0) loss += -delta;
    const slope = segmentSlopeDegrees(valid[i - 1], valid[i]);
    if (slope !== undefined && (maxSlope === undefined || slope > maxSlope)) maxSlope = slope;
  }
  return {
    gain,
    loss,
    min: Math.min(...valid.map((p) => p.elevation)),
    max: Math.max(...valid.map((p) => p.elevation)),
    maxSlope,
  };
}

export function metersToMiles(m: number) { return m / 1609.344; }
export function metersToFeet(m: number) { return m * 3.280839895; }
export function metersToKm(m: number) { return m / 1000; }

export type UnitSystem = 'metric' | 'imperial';

/** "Nice" even spacing between x-axis ticks, aimed at ~5 divisions along the route. */
export function profileAxisStep(totalMeters: number): number {
  const raw = totalMeters / 5;
  if (raw <= 0) return 0;
  const magnitude = Math.pow(10, Math.floor(Math.log10(raw)));
  const norm = raw / magnitude;
  return (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * magnitude;
}

/** Closest profile sample index to a cumulative distance, for chart hover snapping. */
export function nearestProfileSample(cumulative: number[], target: number): number {
  let best = 0;
  let bestDistance = Infinity;
  for (let i = 0; i < cumulative.length; i++) {
    const distance = Math.abs(cumulative[i] - target);
    if (distance < bestDistance) {
      bestDistance = distance;
      best = i;
    }
  }
  return best;
}

/** "#rrggbb" → "rgba(r, g, b, a)" for canvas fills with translucency. */
export function colorToAlpha(hex: string, alpha: number): string {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

// Web-Mercator helpers so profile samples follow the straight lines drawn on the map.
export function mercatorX(lngDeg: number): number { return (lngDeg + 180) / 360; }
export function mercatorY(latDeg: number): number {
  const sin = Math.sin((latDeg * Math.PI) / 180);
  return 0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI);
}
export function inverseMercator(y: number, x: number): { lat: number; lng: number } {
  const lat = Math.atan(Math.sinh(Math.PI * (1 - 2 * y))) * (180 / Math.PI);
  return { lat, lng: x * 360 - 180 };
}

/**
 * Resample the route at a fixed ground spacing so elevation stats reflect the
 * terrain crossed along the lines between points, not just the vertices. Short
 * segments are kept as-is; long segments are interpolated along their drawn
 * (Mercator-straight) path. Interpolated samples have no elevation, so callers
 * fill them from the DEM before computing stats.
 */
export function routeProfilePoints(points: RoutePoint[], stepMeters: number): RoutePoint[] {
  const profile: RoutePoint[] = [];
  if (!points.length) return profile;
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1];
    const b = points[i];
    profile.push(a);
    const length = haversineMeters(a, b);
    if (length <= stepMeters) continue;
    const steps = Math.round(length / stepMeters);
    let ax = mercatorX(a.lon); const ay = mercatorY(a.lat);
    let bx = mercatorX(b.lon); const by = mercatorY(b.lat);
    if (bx - ax > 0.5) bx -= 1; else if (bx - ax < -0.5) bx += 1; // antimeridian wrap
    for (let s = 1; s < steps; s++) {
      const t = s / steps;
      const { lat, lng } = inverseMercator(ay + (by - ay) * t, ax + (bx - ax) * t);
      profile.push({ lat, lon: lng });
    }
  }
  profile.push(points[points.length - 1]);
  return profile;
}
