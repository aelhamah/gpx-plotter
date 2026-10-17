import { DEFAULT_CENTER, DEFAULT_ZOOM, TILE_PROXY_BASE_URL } from './config';
import { loadCachedFix, type CachedFix } from './storage';

/**
 * Choosing what the map opens on.
 *
 * ## Why it matters
 *
 * The basemap's first style and tile requests carry the camera, so the centre the
 * Map is constructed with decides *which tiles are fetched first*. Opening on a
 * fixed default and then jumping to the user is two sets of tile requests, and on
 * a slow connection the first set is the expensive one — it is fetched, discarded,
 * and charged for. Opening in roughly the right place fetches the right tiles once.
 *
 * ## Why this is worth waiting for
 *
 * An IP-derived position arrives over the network, so using it means delaying the
 * Map's construction by one round trip. That is a trade, and it only pays because
 * a viewport of vector tiles is far bigger than one small JSON response. So the
 * wait is bounded: {@link GEO_TIMEOUT_MS}, after which the default is used and
 * the app is no slower than it was before any of this existed.
 *
 * It is also skipped entirely when no proxy is configured, since there is then no
 * `/geo` to ask — an unconfigured build pays nothing rather than paying for a
 * request that cannot succeed.
 *
 * ## Why the estimate is never the whole story
 *
 * It is a city centroid from an IP address, routinely wrong by tens of kilometres
 * and occasionally by a country (VPNs, mobile networks whose exit node is
 * elsewhere). It is a good answer to "which tiles should I ask for first" and not
 * a good answer to anything else, which is why `saved` and `fix` both outrank it
 * and why it is never written to storage as though it were a real fix.
 */

/** Where the startup position came from, in the order they are preferred. */
export type StartupSource = 'saved' | 'fix' | 'estimate' | 'default';

export interface StartupCenter {
  center: [number, number];
  zoom: number;
  source: StartupSource;
}

/**
 * How long to wait for the estimate before giving up on it.
 *
 * Long enough for a Worker on the edge to answer from data it already had — the
 * answer is attached to the connection, so this is one round trip and no upstream
 * fetch. Short enough that a slow or unreachable endpoint costs a visible moment
 * rather than the load it was meant to save.
 */
export const GEO_TIMEOUT_MS = 1_500;

/**
 * Zoom for a position we know precisely, when the user has not said otherwise.
 *
 * Deliberately not `zoomForAccuracy`, which frames the accuracy circle and lands
 * around zoom 13 for a phone fix. That is the right answer to "show me where I
 * am" and the wrong one for "where should I open": this app is about terrain, and
 * a street-level opening frame on first load hides the relief that makes it worth
 * opening. The locate button is still there for the precise answer.
 */
export const FIX_ZOOM = 11;

/** What the Worker sends back. Every field is checked before it is believed. */
export interface GeoEstimate {
  lat: number;
  lon: number;
  city?: string;
  country?: string;
  precision: 'city';
}

export interface StartupInput {
  /** The camera from the last session, if the workspace was restored. */
  saved?: { center: { lng: number; lat: number }; zoom: number } | undefined;
  /** Overrides storage, for tests. */
  cachedFix?: CachedFix | null;
  /** Overrides the network, for tests. */
  estimate?: GeoEstimate | null;
}

/**
 * The position to open on.
 *
 * `saved` first, and this is the one ordering that is worth arguing about.
 * Someone who drew a route in Colorado and closed the tab must come back to
 * Colorado, not to wherever they happen to be sitting — the route they were
 * working on is not visible from their own location, so opening there shows an
 * empty map and makes the app look like it lost their work. Being near the user is
 * only useful when there is no work to return to.
 */
export function chooseStartupCenter(input: StartupInput): StartupCenter {
  if (input.saved) {
    return { center: [input.saved.center.lng, input.saved.center.lat], zoom: input.saved.zoom, source: 'saved' };
  }

  const fix = input.cachedFix ?? loadCachedFix();
  if (fix) return { center: [fix.lon, fix.lat], zoom: FIX_ZOOM, source: 'fix' };

  const estimate = input.estimate;
  if (estimate) {
    return { center: [estimate.lon, estimate.lat], zoom: DEFAULT_ZOOM, source: 'estimate' };
  }

  return { center: DEFAULT_CENTER, zoom: DEFAULT_ZOOM, source: 'default' };
}

/**
 * Ask the Worker roughly where this client is, or give up.
 *
 * Returns null for every failure — no proxy, offline, refused, 204, malformed,
 * slow. None of them are worth surfacing: the caller falls back to the default,
 * which is exactly where it would have started without this, so there is nothing
 * to report and nothing for the user to act on. It must not raise a service
 * failure either — the basemap is not broken when a *hint* about the centre is
 * unavailable, and a banner saying so would be a lie.
 */
export async function fetchGeoEstimate(options: {
  baseUrl?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
} = {}): Promise<GeoEstimate | null> {
  const base = (options.baseUrl ?? TILE_PROXY_BASE_URL).replace(/\/+$/, '');
  // No proxy means no `/geo`. Returning here rather than fetching an obviously
  // broken URL is what keeps an unconfigured build from paying for the timeout.
  if (!base) return null;

  const doFetch = options.fetchImpl ?? fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? GEO_TIMEOUT_MS);
  try {
    const response = await doFetch(`${base}/geo`, { signal: controller.signal, headers: { accept: 'application/json' } });
    // 204 is the Worker's "the edge has no location for you". A successful answer
    // to a question, and the same thing as null as far as the caller is concerned.
    if (!response.ok) return null;
    return parseEstimate(await response.json());
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** The estimate, or null when the body is not one. Never throws. */
export function parseEstimate(body: unknown): GeoEstimate | null {
  const data = body as Partial<GeoEstimate> | null;
  if (!data || typeof data !== 'object') return null;
  const lat = Number(data.lat);
  const lon = Number(data.lon);
  // Bounds-checked rather than trusted: this decides the map's opening frame, and a
  // bad centre is worse than the default it replaced.
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  if (Math.abs(lat) > 90 || Math.abs(lon) > 180) return null;
  return {
    lat,
    lon,
    city: typeof data.city === 'string' ? data.city : undefined,
    country: typeof data.country === 'string' ? data.country : undefined,
    precision: 'city',
  };
}

/**
 * Resolve the opening camera, asking for an estimate only if it would be used.
 *
 * Kept separate from `chooseStartupCenter` so the network call is skipped
 * entirely when a saved view or a cached fix already answers the question —
 * otherwise the common case of returning to your own map would pay a round trip
 * on every load for a value it was never going to read.
 */
export async function resolveStartupCenter(saved?: StartupInput['saved']): Promise<StartupCenter> {
  if (saved) return chooseStartupCenter({ saved });
  const fix = loadCachedFix();
  if (fix) return chooseStartupCenter({ cachedFix: fix });
  const estimate = await fetchGeoEstimate();
  return chooseStartupCenter({ cachedFix: null, estimate });
}