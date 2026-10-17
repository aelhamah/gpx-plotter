/**
 * An approximate location for the client, read out of `request.cf`.
 *
 * ## Why the Worker is the right place to answer this
 *
 * Cloudflare already knows which city an incoming connection arrives from — it
 * has to, to route it — so `request.cf` carries a city-level latitude and
 * longitude on every request that crosses the edge. Answering "where roughly are
 * you" here costs one Worker invocation and **no upstream round trip at all**,
 * because there is no upstream: the answer was attached to the request that
 * arrived.
 *
 * The alternatives both cost more. A third-party geo-IP service means a second
 * hostname to resolve, a second TLS handshake, and the user's IP handed to a
 * company that has no reason to have it — on the critical path of first paint,
 * which is the one moment this app has already decided is tight. `cdn-cgi/trace`
 * is free but returns a country code, which is not fine enough to centre a map
 * on: it picks the right continent and then nothing useful.
 *
 * ## What this is and is not
 *
 * It is a **city centroid derived from an IP address**, and it is routinely
 * wrong — by tens of kilometres for a mobile network whose exit node is in
 * another city, and occasionally by an entire country for a VPN. It is a good
 * enough answer for "which tiles should I ask for first" and not a good enough
 * answer for anything a user would act on.
 *
 * So it is returned with that said in the payload, and the client is expected to
 * treat it as a hint. It is never persisted as if it were a real fix.
 *
 * ## Why the parsing lives here
 *
 * `request.cf` is `undefined` outside a Cloudflare runtime — in tests, in
 * `wrangler dev`, and on any deployment that is not behind the edge — and its
 * fields are typed as optional strings even when the edge did populate them.
 * Turning that into a number or rejecting it is a decision, and it belongs with
 * the other decisions this Worker makes in pure functions that a test can reach
 * without a runtime.
 */

/** An approximate position, good enough to choose a starting tile and nothing more. */
export interface GeoEstimate {
  lat: number;
  lon: number;
  /** City as Cloudflare names it, when it has one. For logs and for saying where. */
  city?: string;
  country?: string;
  /**
   * Always `'city'`. Carried in the payload rather than implied so a client that
   * shows this to somebody can say how wrong it might be.
   */
  precision: 'city';
}

/**
 * The shape of `request.cf` this module reads.
 *
 * Deliberately `Record<string, unknown>` rather than an interface of the four
 * fields it wants: `request.cf` arrives as a bag of optional strings from a
 * network hop, and every field here is checked at runtime anyway. An interface
 * would only move that checking to the call site, where it would be done once
 * instead of once per coordinate.
 */
export type CfLocation = Record<string, unknown> | undefined | null;

/**
 * The estimate, or null when there is not a usable one.
 *
 * Null rather than a zeroed position, because the caller has to be able to tell
 * "Cloudflare did not say" from "Cloudflare said (0, 0)". `(0, 0)` is a real
 * place in the Gulf of Guinea and a plausible-looking answer that would put the
 * map in the wrong ocean, and a client that cannot tell the difference has no way
 * to fall back.
 */
export function geoFromCf(cf: CfLocation): GeoEstimate | null {
  if (!cf) return null;
  const lat = coordinate(cf.latitude, 90);
  const lon = coordinate(cf.longitude, 180);
  // Both or neither: a half-answer is not a position, and treating one missing
  // field as zero would place a caller near the equator or the prime meridian
  // rather than admitting the answer was incomplete.
  if (lat === null || lon === null) return null;
  return {
    lat,
    lon,
    city: text(cf.city),
    country: text(cf.country),
    precision: 'city',
  };
}

/**
 * One coordinate, or null if it is absent, not a number, or off the planet.
 *
 * The bounds are checked rather than trusted because these fields are populated by
 * a network hop rather than by a parser in this process — an out-of-range value
 * would become a centre the map cannot render at all, which is a worse outcome
 * than falling back to the default.
 */
function coordinate(raw: unknown, limit: number): number | null {
  if (typeof raw !== 'string' && typeof raw !== 'number') return null;
  if (typeof raw === 'string' && raw.trim() === '') return null;
  const value = Number(raw);
  if (!Number.isFinite(value)) return null;
  return Math.abs(value) <= limit ? value : null;
}

/** A non-empty string, or undefined. Cloudflare sends `""` for unknown fields. */
function text(raw: unknown): string | undefined {
  if (typeof raw !== 'string') return undefined;
  const trimmed = raw.trim();
  return trimmed === '' ? undefined : trimmed;
}