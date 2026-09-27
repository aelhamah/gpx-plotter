// @vitest-environment jsdom
/**
 * Snapping measured against a real recorded hike rather than a synthetic one.
 *
 * The Halo Ridge (Mt. of the Holy Cross, CO) is 12.5 km of trail with
 * switchbacks, GPS noise and a genuinely off-trail summit ridge. Every bound
 * below was measured against this fixture. They carry headroom so the test
 * states a contract rather than a fingerprint, but they are not arbitrary
 * either — a snap drifting much further lands visibly off the trail on the map.
 *
 * What this catches that the synthetic tests cannot:
 *  - snapping onto *generalised* geometry, which is all a vector tile ever gives;
 *  - following a trail that switchbacks instead of cutting across it;
 *  - a point snapped well onto a trail still being allowed to follow it, which
 *    is the bug behind the removed `TRAIL_FOLLOW_METERS` gate;
 *  - declining to snap where there is genuinely no trail.
 */
import { describe, expect, it } from 'vitest';
import { distanceMeters, nearestLine, TRAIL_SNAP_METERS, type SnapPoint } from '../src/snap';
import { TRAIL_JOIN_METERS, TRAIL_MAX_DETOUR, trailVerticesBetween } from '../src/trailGraph';
import {
  alongTrack,
  distanceToTrack,
  haloRidgeName,
  haloRidgeTrack,
  offsetMeters,
  pathLength,
  percentile,
  trackLength,
  trackNetwork,
} from './helpers/haloRidge';

const track = haloRidgeTrack();
const LENGTH = trackLength(track);
/** The spacing a deep-zoom tile approximates this trail with, from the same source. */
const TILE_SPACING = 25;
const LEG = 200;

const mean = (values: number[]) => values.reduce((a, b) => a + b, 0) / values.length;

describe('the Halo Ridge fixture', () => {
  it('is a real single-track hike that the app imports whole', () => {
    expect(haloRidgeName()).toBe('Mt. of the Holy Cross - Halo Ridge');
    expect(track).toHaveLength(1044);
    const lons = track.map((p) => p.lon);
    const lats = track.map((p) => p.lat);
    expect(Math.min(...lons)).toBeCloseTo(-106.4873, 4);
    expect(Math.max(...lons)).toBeCloseTo(-106.4325, 4);
    expect(Math.min(...lats)).toBeCloseTo(39.4563, 4);
    expect(Math.max(...lats)).toBeCloseTo(39.5004, 4);
  });

  it('spans the climb the file claims', () => {
    expect(LENGTH / 1000).toBeGreaterThan(12);
    expect(LENGTH / 1000).toBeLessThan(13);
    const elevations = track.map((p) => p.elevation ?? Number.NaN);
    expect(elevations.every(Number.isFinite)).toBe(true);
    expect(Math.min(...elevations)).toBeCloseTo(3159, 0);
    expect(Math.max(...elevations)).toBeCloseTo(4259, 0);
  });

  it('is dense enough to sample along but not so dense it hides anything', () => {
    // ~12 m mean spacing: fine enough to resolve the trail, coarse enough that a
    // 40 m snap radius is a real test rather than a foregone conclusion.
    expect(LENGTH / track.length).toBeGreaterThan(10);
    expect(LENGTH / track.length).toBeLessThan(14);
  });
});

describe('snapping onto generalised trail geometry', () => {
  const network = (spacing: number) => trackNetwork(track, spacing);

  /** Clicks a realistic distance off the trail, spread along its whole length. */
  const clicks = (offset: number): SnapPoint[] => {
    const out: SnapPoint[] = [];
    for (let d = 0; d < LENGTH; d += 50) out.push(offsetMeters(alongTrack(track, d), offset, d * 0.017));
    return out;
  };

  const measure = (spacing: number, offset: number) => {
    const candidates = network(spacing);
    const errors: number[] = [];
    let furthestFromClick = 0;
    for (const click of clicks(offset)) {
      const match = nearestLine(click, candidates, TRAIL_SNAP_METERS);
      if (!match) continue;
      errors.push(distanceToTrack(match.result.point));
      furthestFromClick = Math.max(furthestFromClick, distanceMeters(click, match.result.point));
    }
    return { errors, total: clicks(offset).length, furthestFromClick };
  };

  it('finds the trail for a click inside the snap radius', () => {
    const { errors, total } = measure(TILE_SPACING, 8);
    expect(total).toBeGreaterThan(200);
    expect(errors).toHaveLength(total);
  });

  it('lands on the trail, to within the geometry it was given', () => {
    // Against 25 m-spaced geometry the recorded trail and the simplified line
    // differ by a couple of metres; that is the accuracy a snap can offer.
    const { errors } = measure(TILE_SPACING, 8);
    expect(mean(errors)).toBeLessThan(3);
    expect(percentile(errors, 0.95)).toBeLessThan(10);
  });

  it('never moves a point further than the radius it promised', () => {
    // The guarantee the snap radius makes is about the click, not the truth:
    // a point is moved at most TRAIL_SNAP_METERS, whatever the geometry's own
    // generalisation error happens to be on top of that.
    for (const spacing of [TILE_SPACING, 100, 400]) {
      expect(measure(spacing, 8).furthestFromClick).toBeLessThan(TRAIL_SNAP_METERS);
    }
  });

  it('drifts further from the real trail as the geometry gets coarser', () => {
    // The trade-off the snap zoom exists to manage: coarser tiles sit further
    // from the real trail and eventually stop carrying it at all.
    const fine = measure(100, 8);
    const coarse = measure(400, 8);

    expect(mean(coarse.errors)).toBeGreaterThan(mean(fine.errors) * 2);
    expect(coarse.errors.length).toBeLessThan(fine.total);
  });

  it('does not invent a trail where there is none', () => {
    // The summit ridge is not a mapped path. A snapper that grabbed the nearest
    // candidate regardless of distance would drag the route off the ridge.
    let declined = 0;
    let total = 0;
    for (let d = 0; d < LENGTH; d += 50) {
      const point = alongTrack(track, d);
      const perDegreeLon = 111320 * Math.cos((point.lat * Math.PI) / 180);
      const offRidge = { lon: point.lon + 200 / perDegreeLon, lat: point.lat + 150 / 111320 };
      total++;
      if (!nearestLine(offRidge, [track], TRAIL_SNAP_METERS)) declined++;
    }
    expect(declined / total).toBeGreaterThan(0.8);
  });
});

describe('following a recorded trail', () => {
  const candidates = trackNetwork(track, TILE_SPACING);

  let cachedLegs: { vertices: SnapPoint[]; ratio: number }[] | null = null;
  /** Every 200 m leg of the trail, snapped at both ends. Computed once. */
  const legs = () => {
    if (cachedLegs) return cachedLegs;
    const found: { vertices: SnapPoint[]; ratio: number }[] = [];
    for (let d = 0; d + LEG < LENGTH; d += LEG) {
      const start = nearestLine(alongTrack(track, d), candidates, TRAIL_SNAP_METERS);
      const end = nearestLine(alongTrack(track, d + LEG), candidates, TRAIL_SNAP_METERS);
      if (!start || !end) continue;
      const vertices = trailVerticesBetween(candidates, start.result.point, end.result.point, TRAIL_SNAP_METERS);
      found.push({
        vertices,
        ratio:
          pathLength([start.result.point, ...vertices, end.result.point]) /
          distanceMeters(start.result.point, end.result.point),
      });
    }
    cachedLegs = found;
    return found;
  };

  it('routes every leg of a 200 m spacing rather than cutting straight', () => {
    const found = legs();
    expect(found.length).toBeGreaterThan(50);
    expect(found.every((leg) => leg.vertices.length > 0)).toBe(true);
  });

  it('walks the switchbacks instead of shortcutting them', () => {
    // The point of following: where the trail folds back, the routed path is
    // substantially longer than the straight line between the same two ends.
    const ratios = legs().map((leg) => leg.ratio);
    expect(percentile(ratios, 0.5)).toBeGreaterThan(1.02);
    expect(Math.max(...ratios)).toBeGreaterThan(2);
  });

  it('keeps every spliced vertex on the recorded trail', () => {
    let worst = 0;
    for (const leg of legs()) {
      for (const vertex of leg.vertices) worst = Math.max(worst, distanceToTrack(vertex));
    }
    expect(worst).toBeLessThan(10);
  });

  it('never trips the detour guard on real terrain', () => {
    // The guard exists to reject a wild detour, not to clip real switchbacks.
    // This trail's worst leg comes within a hair of the limit, so the two are
    // close enough to be worth pinning together.
    expect(Math.max(...legs().map((leg) => leg.ratio))).toBeLessThan(TRAIL_MAX_DETOUR);
  });

  it('follows for a point snapped well clear of the trail, not just one right on it', () => {
    // The regression this pins. Following used to require the drawn point to be
    // within 15 m of a trail while snapping only required 40 m, so a point
    // placed further out had been snapped onto the trail and then refused the
    // follow. That is what left drawn routes half hugging the trail and half
    // cutting straight across it.
    const full = [track];
    let followed = 0;
    let legsSeen = 0;
    for (let d = 0; d + LEG < LENGTH; d += LEG) {
      const previous = offsetMeters(alongTrack(track, d), 30, d * 0.01);
      // Where the trail runs back alongside itself, a fixed offset can land
      // closer to it than asked; only count legs that really are out past the
      // old 15 m gate but still inside the radius that snapped them.
      const off = distanceToTrack(previous);
      if (off <= 15 || off > TRAIL_SNAP_METERS) continue;
      const end = nearestLine(offsetMeters(alongTrack(track, d + LEG), 30, d * 0.01), full, TRAIL_SNAP_METERS);
      if (!end) continue;
      legsSeen++;
      if (trailVerticesBetween(full, previous, end.result.point, TRAIL_SNAP_METERS).length > 0) followed++;
    }
    // Most of the 200 m legs sit far enough out to have been refused by the old
    // gate, so this is the bulk of the track and not a hand-picked corner.
    expect(legsSeen).toBeGreaterThan(30);
    expect(followed).toBe(legsSeen);
  });
});

describe('a way split into pieces', () => {
  const splitAt = Math.floor(track.length * 0.45);

  /** The track cut in two, `dropped` points missing from the middle. */
  const split = (dropped: number): SnapPoint[][] => {
    const segment = (from: number, to: number) => track.slice(from, to).map((p) => ({ lon: p.lon, lat: p.lat }));
    return [segment(0, splitAt), segment(splitAt + dropped, track.length)];
  };

  /** Route from the very end of the first piece to the start of the second. */
  const crossTheSplit = (dropped: number) => {
    const [first, second] = split(dropped);
    const looseEnd = first[first.length - 1];
    const farEnd = second[second.length - 1];
    const gap = distanceMeters(looseEnd, second[0]);
    const end = nearestLine(farEnd, [second], TRAIL_SNAP_METERS);
    if (!end) return { gap, vertices: [] as SnapPoint[] };
    return { gap, vertices: trailVerticesBetween([first, second], looseEnd, end.result.point, TRAIL_SNAP_METERS) };
  };

  it('bridges loose ends that a way split left within reach', () => {
    // One OSM way is usually several features, so continuity has to be rebuilt
    // from loose ends or the whole trail reads as a row of unrelated pieces.
    const { gap, vertices } = crossTheSplit(3);
    expect(gap).toBeGreaterThan(10);
    expect(gap).toBeLessThan(TRAIL_JOIN_METERS);
    expect(vertices.length).toBeGreaterThan(0);
  });

  it('declines rather than guessing when the split is out of reach', () => {
    const { gap, vertices } = crossTheSplit(8);
    expect(gap).toBeGreaterThan(TRAIL_JOIN_METERS);
    // No invented connecting segment: the caller draws straight instead.
    expect(vertices).toEqual([]);
  });
});
