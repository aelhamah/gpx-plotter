import type { RoutePoint } from './gpx';
import { distanceMeters } from './snap';

/** Ground tolerance (m) for treating the seam of two routes as "the same path". */
export const MERGE_OVERLAP_METERS = 10;

function reversePoints(points: RoutePoint[]): RoutePoint[] {
  return [...points].reverse();
}

/** Unit travel direction of a segment, or null when it has near-zero length. */
function unitDirection(a: RoutePoint, b: RoutePoint): { dx: number; dy: number } | null {
  const dx = b.lon - a.lon;
  const dy = b.lat - a.lat;
  const length = Math.hypot(dx, dy);
  return length < 1e-12 ? null : { dx: dx / length, dy: dy / length };
}

interface OrientedMerge {
  /** First half of the merged trace, oriented so its last point is the joint. */
  first: RoutePoint[];
  /** Second half, oriented so its first point is the joint. */
  second: RoutePoint[];
  /** Distance (m) between the two joint endpoints. */
  gapMeters: number;
}

/**
 * Arrange the two routes so the merged trace connects their nearest endpoints:
 * one of the four start/end pairings is chosen and routes are reversed as needed.
 */
function orientMerge(a: RoutePoint[], b: RoutePoint[]): OrientedMerge {
  const aStart = a[0];
  const aEnd = a[a.length - 1];
  const bStart = b[0];
  const bEnd = b[b.length - 1];
  const aRev = reversePoints(a);
  const bRev = reversePoints(b);
  const options: OrientedMerge[] = [
    { first: a, second: b, gapMeters: distanceMeters(aEnd, bStart) },
    { first: a, second: bRev, gapMeters: distanceMeters(aEnd, bEnd) },
    { first: aRev, second: b, gapMeters: distanceMeters(aStart, bStart) },
    { first: aRev, second: bRev, gapMeters: distanceMeters(aStart, bEnd) },
  ];
  return options.reduce((best, option) => (option.gapMeters < best.gapMeters ? option : best));
}

/**
 * Count how many leading points of `second` duplicate the tail of `first`
 * within `overlapMeters`, measured pairwise from the joint outward. Only a
 * *same-direction* seam is trimmed: when the second route heads back the way
 * the first came (an out-and-back return), every point is preserved.
 */
function trimDuplicatedHead(first: RoutePoint[], second: RoutePoint[], overlapMeters: number): number {
  if (first.length < 2 || second.length < 2) return 0;
  const tailDir = unitDirection(first[first.length - 2], first[first.length - 1]);
  const headDir = unitDirection(second[0], second[1]);
  if (!tailDir || !headDir) return 0;
  const dot = tailDir.dx * headDir.dx + tailDir.dy * headDir.dy;
  if (dot <= 0) return 0;
  let trim = 0;
  let joint = first.length - 1;
  while (trim < second.length - 1 && joint - trim > 0) {
    if (distanceMeters(first[joint - trim], second[trim]) > overlapMeters + 1e-6) break;
    trim++;
  }
  return trim;
}

/**
 * Combine two routes into one continuous trace.
 *
 * The routes are connected at the endpoints nearest each other, reversing them
 * as needed so the merged trace runs from one free end, through the first
 * route, across the joint, and out along the second. If the two traces share a
 * stretch of ground near the joint (within `overlapMeters`, default 10 m) and
 * are walking it in the same direction, the duplicated head of the second
 * route is dropped so shared ground is only covered once.
 */
export function mergeRoutePoints(
  a: RoutePoint[],
  b: RoutePoint[],
  overlapMeters: number = MERGE_OVERLAP_METERS,
): RoutePoint[] {
  if (a.length === 0) return [...b];
  if (b.length === 0) return [...a];
  const { first, second } = orientMerge(a, b);
  const trim = trimDuplicatedHead(first, second, overlapMeters);
  return trim === 0 ? [...first, ...second] : [...first, ...second.slice(trim)];
}