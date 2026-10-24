import { DEFAULT_CENTER, DEFAULT_ZOOM, TILE_PROXY_BASE_URL } from './config';
import { loadCachedFix, saveCachedFix, LOCATION_MAX_ACCURACY_METERS, type CachedFix } from './storage';

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
 * On a visit with nothing remembered — no saved view, no cached fix — the browser
 * is asked for a real position too, which is what raises the permission prompt.
 * That wait is bounded by {@link STARTUP_FIX_TIMEOUT_MS} for the same reason: an
 * ignored dialog must cost a moment, not the load. The estimate runs alongside,
 * so the two waits overlap rather than stack.
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
 * How long to wait for the browser's position before opening without it.
 *
 * The browser shows its permission dialog while this clock runs, so this is also
 * how long an ignored dialog holds the map hostage. Long enough that reading the
 * dialog and clicking "Allow" still lands this load on a real fix — a granted
 * position that arrives in time is the whole point of asking. Short enough that
 * someone who ignores it sees the map (on the estimate) rather than a blank page.
 *
 * A grant that arrives *after* this budget is not wasted: it is written to
 * storage, so the next load opens on it without asking again.
 */
export const STARTUP_FIX_TIMEOUT_MS = 3_000;

/**
 * How stale a browser-cached position may be and still be returned without a
 * fresh lookup.
 *
 * Only matters when permission is already granted and no dialog appears — the
 * rare visit where our own cached fix aged out but the browser still remembers
 * one. A minute old is recent enough to be the right valley, and old enough that
 * the common just-granted case answers instantly instead of waiting on the
 * network or GPS.
 */
export const STARTUP_FIX_MAX_AGE_MS = 60_000;

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

/** The slice of `GeolocationPosition` the startup fix uses, structurally. */
export interface StartupFixPosition {
  coords: { latitude: number; longitude: number; accuracy: number };
  timestamp: number;
}

/** The slice of `navigator.geolocation` the startup fix uses, structurally. */
export interface StartupGeolocation {
  getCurrentPosition(
    success: (position: StartupFixPosition) => void,
    error?: (error: unknown) => void,
    options?: { enableHighAccuracy?: boolean; timeout?: number; maximumAge?: number },
  ): void;
}

/**
 * The browser's position as a `CachedFix`, or null when it is not one worth
 * keeping. Mirrors the bar `loadCachedFix` applies on the way back out, so a fix
 * is never stored only to be rejected on the next load.
 */
export function normalizeStartupFix(position: StartupFixPosition | null | undefined): CachedFix | null {
  const coords = position?.coords;
  if (!coords) return null;
  const lat = Number(coords.latitude);
  const lon = Number(coords.longitude);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  if (Math.abs(lat) > 90 || Math.abs(lon) > 180) return null;
  // A fix with kilometres of accuracy is no better than the IP centroid it would
  // outrank — the same reasoning `LOCATION_MAX_ACCURACY_METERS` encodes for the
  // cached fix, applied here so a coarse network answer falls through to the
  // estimate rather than replacing it.
  const accuracy = Number(coords.accuracy);
  if (!Number.isFinite(accuracy) || accuracy < 0 || accuracy > LOCATION_MAX_ACCURACY_METERS) return null;
  const at = Number(position?.timestamp);
  return { lon, lat, at: Number.isFinite(at) ? at : Date.now(), accuracyMeters: accuracy };
}

/**
 * Ask the browser for a position — which is what raises the permission prompt on
 * a first visit — or give up.
 *
 * The dialog is user-paced, so the wait is bounded: an ignored prompt resolves as
 * null after {@link STARTUP_FIX_TIMEOUT_MS} and the caller opens on the estimate
 * instead. A grant that lands *after* that budget still writes itself to storage:
 * this load has already opened elsewhere, but the next one opens right, and the
 * question is never asked again.
 *
 * Every failure resolves as null rather than throwing — denied, unsupported,
 * insecure context, timeout. None are worth surfacing: falling back to the
 * estimate is exactly where the app would have opened without any of this.
 */
export async function requestStartupFix(options: {
  geolocation?: StartupGeolocation | null;
  timeoutMs?: number;
} = {}): Promise<CachedFix | null> {
  const geo = options.geolocation
    ?? (typeof navigator !== 'undefined' && 'geolocation' in navigator
      ? navigator.geolocation as StartupGeolocation
      : null);
  // No geolocation — plain HTTP, or a browser without it. Nothing to prompt with.
  if (!geo) return null;

  const timeoutMs = options.timeoutMs ?? STARTUP_FIX_TIMEOUT_MS;
  return new Promise((resolve) => {
    let settled = false;
    const settle = (value: CachedFix | null) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    const timer = setTimeout(() => settle(null), timeoutMs);
    try {
      geo.getCurrentPosition(
        (position) => {
          clearTimeout(timer);
          const fix = normalizeStartupFix(position);
          // Remember a fix worth keeping even when this load can no longer use it.
          // A grant answers the prompt; storage is what makes that a one-time act.
          if (fix) saveCachedFix(fix);
          settle(fix);
        },
        () => {
          clearTimeout(timer);
          settle(null);
        },
        { enableHighAccuracy: false, timeout: timeoutMs, maximumAge: STARTUP_FIX_MAX_AGE_MS },
      );
    } catch {
      // Some engines throw synchronously on a refused call (no secure context).
      clearTimeout(timer);
      settle(null);
    }
  });
}

/**
 * Resolve the opening camera, asking for a position and an estimate only if
 * either would be used.
 *
 * Kept separate from `chooseStartupCenter` so the prompt and the network call are
 * skipped entirely when a saved view or a cached fix already answers the question —
 * otherwise the common case of returning to your own map would pay a round trip,
 * and a permission prompt, on every load for a value it was never going to read.
 *
 * The two requests run in parallel rather than in sequence: the dialog is paced by
 * the user and the estimate by the network, so overlapping them means the map
 * waits for whichever takes longest only when *both* are slow.
 */
export async function resolveStartupCenter(saved?: StartupInput['saved']): Promise<StartupCenter> {
  if (saved) return chooseStartupCenter({ saved });
  const cached = loadCachedFix();
  if (cached) return chooseStartupCenter({ cachedFix: cached });
  const [fix, estimate] = await Promise.all([requestStartupFix(), fetchGeoEstimate()]);
  return chooseStartupCenter({ cachedFix: fix, estimate });
}
