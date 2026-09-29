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

/**
 * Whether a profile carries no elevation of its own, so the DEM is the only
 * thing that can fill it.
 */
export function profileNeedsTerrain(profile: RoutePoint[]): boolean {
  return !profile.some((point) => Number.isFinite(point.elevation));
}

/** The indices of a profile whose gaps need filling, each one only once. */
function gapIndices(track: RoutePoint[]): number[] {
  const gaps: number[] = [];
  for (let i = 0; i < track.length; i++) {
    if (!Number.isFinite(track[i].elevation)) gaps.push(i);
  }
  return gaps;
}

/**
 * The samples whose elevation the DEM has to be read for: every gap, plus the
 * samples with an elevation of their own that bound each run of them, since that
 * is where the correction from the terrain is anchored. Asking for the whole
 * profile would be a waste — a recording with dense fixes resamples entirely
 * onto its own vertices and has no gaps at all.
 */
export function terrainSamplesNeeded(track: RoutePoint[]): number[] {
  const needed = new Set<number>();
  const gaps = gapIndices(track);
  for (const gap of gaps) {
    if (gap > 0) needed.add(gap - 1);
    if (gap + 1 < track.length) needed.add(gap + 1);
  }
  for (const gap of gaps) needed.add(gap);
  return [...needed].sort((a, b) => a - b);
}

/**
 * Fill each missing elevation by interpolating between the nearest known ones on
 * either side of it.
 *
 * The fallback for when the DEM cannot be read, and all a profile with no
 * elevation of its own needs. A run at either end has only one neighbour to work
 * from, so it is held flat at that neighbour's value rather than extrapolated.
 */
export function interpolateProfileElevations(profile: RoutePoint[]): RoutePoint[] {
  return profile.map((point, index) => ({
    ...point,
    elevation: interpolateAcrossGaps(profile.map(valueOrUndefined))[index],
  }));
}

/**
 * The DEM's own shape, corrected to pass through the elevations the track
 * recorded.
 *
 * The DEM knows the ground between the route's vertices and the track knows the
 * ground at them, so each of the track's samples says how far above or below the
 * DEM it put the route at that point. Carrying that correction across the gaps
 * keeps the real undulations between the vertices while making the series agree
 * with the track everywhere the track has an opinion. Two sources that disagree
 * cannot sawtooth when one is expressed as an offset from the other — which is
 * what put a dip in the profile at every vertex when both were used raw, worth
 * hundreds of metres on a hand-drawn route.
 *
 * A sample with an elevation of its own keeps it. A gap the DEM could not answer
 * falls back to the track's own line between its vertices, so a failed lookup
 * costs that one sample its detail and nothing else. A track with no elevation
 * at all has nothing to anchor to, so the DEM is used as it stands.
 */
export function blendTerrainElevations(terrain: (number | undefined)[], track: RoutePoint[]): RoutePoint[] {
  if (!track.some((point) => Number.isFinite(point.elevation))) {
    return track.map((point, index) => ({ ...point, elevation: terrain[index] }));
  }
  const correction = interpolateAcrossGaps(track.map((point, index) => {
    if (!Number.isFinite(point.elevation) || !Number.isFinite(terrain[index])) return undefined;
    return (point.elevation as number) - (terrain[index] as number);
  }));
  const ground = interpolateAcrossGaps(track.map((point, index) => {
    if (Number.isFinite(point.elevation)) return point.elevation;
    return Number.isFinite(terrain[index]) ? terrain[index] : undefined;
  }));
  return track.map((point, index) => ({
    ...point,
    // A sample the track measured is the track's answer, not the terrain's plus a
    // correction to it; the correction is only for the gaps.
    elevation: Number.isFinite(point.elevation)
      ? (point.elevation as number)
      : (ground[index] ?? 0) + (correction[index] ?? 0),
  }));
}

function valueOrUndefined(point: RoutePoint): number | undefined {
  return Number.isFinite(point.elevation) ? (point.elevation as number) : undefined;
}

/**
 * Fill each undefined entry of a series by interpolating between the defined ones
 * on either side, holding the ends flat.
 */
function interpolateAcrossGaps(series: (number | undefined)[]): (number | undefined)[] {
  const known = series
    .map((value, index) => (value !== undefined ? index : -1))
    .filter((index) => index >= 0);
  if (!known.length) return series;
  const first = known[0];
  const last = known[known.length - 1];
  const filled = series.slice();
  for (let i = 0; i <= first; i++) filled[i] = series[first];
  for (let i = last; i < filled.length; i++) filled[i] = series[last];
  for (let k = 1; k < known.length; k++) {
    const lower = known[k - 1];
    const upper = known[k];
    if (upper <= lower + 1) continue;
    const from = series[lower] as number;
    const to = series[upper] as number;
    for (let i = lower + 1; i < upper; i++) {
      filled[i] = from + (to - from) * ((i - lower) / (upper - lower));
    }
  }
  return filled;
}
