/**
 * The Halo Ridge fixture, and the small amount of geometry needed to drive
 * snapping against it.
 *
 * `haloridge14ers.gpx` is a real recorded hike up Mt. of the Holy Cross in
 * Colorado: 1044 track points over 12.5 km, climbing 3159 m to 4259 m. It is
 * the most useful thing in the test suite for snapping, because it is the only
 * input with the properties that actually break snapping:
 *
 *  - **Switchbacks.** The trail folds back on itself, so a leg between two
 *    nearby points can be 3x further along the ground than the straight line
 *    between them. Synthetic straight lines never exercise this.
 *  - **Generous GPS noise and simplification.** Real tracks wander. Snapping
 *    has to cope with geometry that is not a clean polyline.
 *  - **Genuinely off-trail sections.** The summit ridge is not a mapped path,
 *    so a correct snapper has to decline to snap there rather than grab the
 *    nearest thing.
 *
 * Nothing here reaches the network. The track stands in for the tileset: run
 * through `trackNetwork` it is a stand-in for the *simplified* geometry a vector
 * tile publishes, which is exactly what snapping is given in production.
 */

import gpxText from '../fixtures/haloridge14ers.gpx?raw';
import { parseGPX } from '../../src/gpx';
import { distanceMeters, projectToSegment, type SnapPoint } from '../../src/snap';

export interface TrackPoint extends SnapPoint {
  elevation?: number;
}

let cached: TrackPoint[] | null = null;

/** The recording, parsed by the app's own GPX reader. */
export function haloRidgeTrack(): TrackPoint[] {
  if (!cached) cached = parseGPX(gpxText).routes[0].points as TrackPoint[];
  return cached;
}

/** The track's name, as recorded. */
export function haloRidgeName(): string {
  return parseGPX(gpxText).routes[0].name;
}

/** Total length of a polyline in meters. */
export function trackLength(points: SnapPoint[]): number {
  let total = 0;
  for (let i = 0; i + 1 < points.length; i++) total += distanceMeters(points[i], points[i + 1]);
  return total;
}

/**
 * The point `meters` along the track. Real tracks have uneven point spacing, so
 * walking the index would put the sample in the wrong place; this interpolates
 * against distance instead.
 */
export function alongTrack(points: SnapPoint[], meters: number): SnapPoint {
  let walked = 0;
  for (let i = 0; i + 1 < points.length; i++) {
    const step = distanceMeters(points[i], points[i + 1]);
    if (walked + step >= meters) {
      const t = step === 0 ? 0 : (meters - walked) / step;
      return {
        lon: points[i].lon + (points[i + 1].lon - points[i].lon) * t,
        lat: points[i].lat + (points[i + 1].lat - points[i].lat) * t,
      };
    }
    walked += step;
  }
  return points[points.length - 1];
}

/**
 * The track as a candidate network, keeping one vertex every `spacingMeters`.
 *
 * This is what a vector tile hands the snapper: the same trail, generalised. The
 * coarser the spacing, the more a snap can drift from the recorded line, which
 * is the trade-off the snap zoom exists to manage.
 */
export function trackNetwork(points: SnapPoint[], spacingMeters: number): SnapPoint[][] {
  const kept: SnapPoint[] = [];
  let next = 0;
  let walked = 0;
  for (let i = 0; i < points.length; i++) {
    if (i > 0) walked += distanceMeters(points[i - 1], points[i]);
    if (walked >= next) {
      kept.push({ lon: points[i].lon, lat: points[i].lat });
      next = walked + spacingMeters;
    }
  }
  const last = points[points.length - 1];
  kept.push({ lon: last.lon, lat: last.lat });
  return [kept];
}

/** Displace a point by meters at a bearing, the way a click misses a trail. */
export function offsetMeters(point: SnapPoint, meters: number, bearing: number): SnapPoint {
  const perDegreeLon = 111320 * Math.cos((point.lat * Math.PI) / 180);
  return {
    lon: point.lon + (meters * Math.cos(bearing)) / perDegreeLon,
    lat: point.lat + (meters * Math.sin(bearing)) / 111320,
  };
}

/** Shortest distance from a point to the full-resolution recording. */
export function distanceToTrack(point: SnapPoint, track: SnapPoint[] = haloRidgeTrack()): number {
  let best = Infinity;
  for (let i = 0; i + 1 < track.length; i++) {
    best = Math.min(best, distanceMeters(point, projectToSegment(point, track[i], track[i + 1])));
  }
  return best;
}

/** Length of a routed path. */
export function pathLength(path: SnapPoint[]): number {
  return trackLength(path);
}

export function percentile(values: number[], fraction: number): number {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))];
}
