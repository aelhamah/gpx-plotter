/**
 * Pure geometry for snapping waypoints/route points onto candidate geometry
 * (trail lines, peak points). No I/O here; candidate collection lives in
 * `snapSources`, tile decoding in `mvt`.
 *
 * Distances use a local flat-earth approximation (meters), which is exact
 * enough for the short thresholds involved (tens to a few hundred meters).
 */

/** Max distance (m) a drawn route point may be from a trail to snap onto it. */
export const TRAIL_SNAP_METERS = 40;
/** Max distance (m) from a trail for the route to run *along* it between points. */
export const TRAIL_FOLLOW_METERS = 15;
/** Max distance (m) a placed waypoint may be from a peak to snap onto it. */
export const PEAK_SNAP_METERS = 250;

export interface SnapPoint {
  lon: number;
  lat: number;
}

/** Great-circle-free meter distance between two points (flat at local scale). */
export function distanceMeters(a: SnapPoint, b: SnapPoint): number {
  const midLat = ((a.lat + b.lat) / 2) * (Math.PI / 180);
  const dx = (b.lon - a.lon) * 111320 * Math.cos(midLat);
  const dy = (b.lat - a.lat) * 110574;
  return Math.hypot(dx, dy);
}

function midLatRadians(a: SnapPoint, b: SnapPoint): number {
  return (a.lat + b.lat) * (Math.PI / 180) / 2;
}

/** Closest point on segment [a, b] to p (linear interpolation in lon/lat). */
export function projectToSegment(p: SnapPoint, a: SnapPoint, b: SnapPoint): SnapPoint {
  const midLat = midLatRadians(a, b);
  const lonScale = Math.cos(midLat);
  const ax = a.lon * lonScale;
  const ay = a.lat;
  const bx = b.lon * lonScale;
  const by = b.lat;
  const px = p.lon * lonScale;
  const py = p.lat;
  const abx = bx - ax;
  const aby = by - ay;
  const apx = px - ax;
  const apy = py - ay;
  const ab2 = abx * abx + aby * aby;
  const t = ab2 === 0 ? 0 : Math.max(0, Math.min(1, (apx * abx + apy * aby) / ab2));
  return { lon: a.lon + (b.lon - a.lon) * t, lat: a.lat + (b.lat - a.lat) * t };
}

export interface SnapSegment {
  a: SnapPoint;
  b: SnapPoint;
  /** Position of the projection along the segment, 0..1. */
  t: number;
}

export interface SnapResult {
  point: SnapPoint;
  distanceMeters: number;
  /** The segment the point was projected onto (absent for single-point lines). */
  segment?: SnapSegment;
}

export function nearestOnLine(p: SnapPoint, line: SnapPoint[], maxMeters: number): SnapResult | null {
  let best: SnapResult | null = null;
  if (line.length === 0) return null;
  if (line.length === 1) {
    const distance = distanceMeters(p, line[0]);
    return distance <= maxMeters ? { point: line[0], distanceMeters: distance } : null;
  }
  for (let i = 0; i < line.length - 1; i++) {
    const a = line[i];
    const b = line[i + 1];
    const point = projectToSegment(p, a, b);
    const distance = distanceMeters(p, point);
    if (distance <= maxMeters && (best === null || distance < best.distanceMeters)) {
      const midLat = midLatRadians(a, b);
      const lonScale = Math.cos(midLat);
      const abx = (b.lon - a.lon) * lonScale;
      const aby = b.lat - a.lat;
      const ab2 = abx * abx + aby * aby;
      const apx = (point.lon - a.lon) * lonScale;
      const apy = point.lat - a.lat;
      const t = ab2 === 0 ? 0 : Math.max(0, Math.min(1, (apx * abx + apy * aby) / ab2));
      best = { point, distanceMeters: distance, segment: { a, b, t } };
    }
  }
  return best;
}

export interface LineSnapResult {
  line: SnapPoint[];
  result: SnapResult;
}

/** Nearest snap target along with the polyline it belongs to (needed to follow trails). */
export function nearestLine(p: SnapPoint, lines: SnapPoint[][], maxMeters: number): LineSnapResult | null {
  let best: LineSnapResult | null = null;
  for (const line of lines) {
    const result = nearestOnLine(p, line, maxMeters);
    if (result !== null && (best === null || result.distanceMeters < best.result.distanceMeters)) {
      best = { line, result };
    }
  }
  return best;
}

/**
 * Nearest snap target across many polylines, within `maxMeters`. Each line may
 * be a single peak point (one entry) or a trail as [point, point, ...].
 */
export function nearestSnap(
  p: SnapPoint,
  lines: SnapPoint[][],
  maxMeters: number,
): SnapResult | null {
  return nearestLine(p, lines, maxMeters)?.result ?? null;
}