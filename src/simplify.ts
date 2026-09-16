/**
 * Reduce a dense GPS track to at most `maxPoints` vertices.
 *
 * The app renders one DOM marker per route point, so importing a raw Strava
 * track (tens of thousands of fixes) can freeze the page. We thin the track by
 * walking it and keeping a point only once we've moved at least `threshold`
 * away from the last kept point (the first and last points are always kept).
 * A short binary search picks the smallest threshold whose result still fits
 * within `maxPoints`, so the output lands as close to the target as possible.
 */
export function downsamplePoints<T extends { lat: number; lon: number }>(points: T[], maxPoints: number): T[] {
  const n = points.length;
  if (n <= 2 || maxPoints < 2 || maxPoints >= n) return points.slice();

  const cosLat = Math.cos((points[0].lat * Math.PI) / 180);
  const distance = (a: T, b: T) => Math.hypot((b.lon - a.lon) * cosLat, b.lat - a.lat);

  let length = 0;
  for (let i = 1; i < n; i++) length += distance(points[i - 1], points[i]);

  if (length === 0) {
    const stride = (n - 1) / (maxPoints - 1);
    const even: T[] = [];
    for (let i = 0; i < maxPoints - 1; i++) even.push(points[Math.round(i * stride)]);
    even.push(points[n - 1]);
    return even;
  }

  const decimate = (threshold: number): T[] => {
    const kept: T[] = [points[0]];
    let last = points[0];
    for (let i = 1; i < n - 1; i++) {
      if (distance(last, points[i]) >= threshold) {
        kept.push(points[i]);
        last = points[i];
      }
    }
    kept.push(points[n - 1]);
    return kept;
  };

  let lo = 0;
  let hi = length;
  let best = decimate(length);
  for (let i = 0; i < 24; i++) {
    const mid = (lo + hi) / 2;
    const candidate = decimate(mid);
    if (candidate.length > maxPoints) lo = mid;
    else { hi = mid; best = candidate; }
  }
  return best;
}

/** Points above this count trigger the import downsampling dialog. */
export const DOWNSAMPLE_PROMPT_THRESHOLD = 500;
