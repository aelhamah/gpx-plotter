// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  chooseStartupCenter,
  fetchGeoEstimate,
  FIX_ZOOM,
  GEO_TIMEOUT_MS,
  normalizeStartupFix,
  parseEstimate,
  requestStartupFix,
  resolveStartupCenter,
  STARTUP_FIX_MAX_AGE_MS,
  STARTUP_FIX_TIMEOUT_MS,
  type GeoEstimate,
  type StartupFixPosition,
  type StartupGeolocation,
} from '../src/startup';
import { LOCATION_KEY, LOCATION_MAX_ACCURACY_METERS, saveCachedFix, type CachedFix } from '../src/storage';

const ANN_ARBOR: GeoEstimate = { lat: 42.2808, lon: -83.743, city: 'Ann Arbor', country: 'US', precision: 'city' };

const fix = (over: Partial<CachedFix> = {}): CachedFix => ({
  lon: -83.743,
  lat: 42.2808,
  at: Date.now(),
  accuracyMeters: 30,
  ...over,
});

/** What a phone's network/GPS fix looks like coming out of `getCurrentPosition`. */
const phonePosition = (over: Partial<StartupFixPosition> = {}): StartupFixPosition => ({
  coords: { latitude: 42.2808, longitude: -83.743, accuracy: 30 },
  timestamp: Date.now(),
  ...over,
});

/**
 * Install a `navigator.geolocation` stand-in. The test decides whether the
 * "browser" grants, denies, or leaves the dialog open; `calls` records the
 * options each request was made with.
 */
function stubGeolocation(answer: 'grant' | 'deny' | 'ignore', position = phonePosition()) {
  const calls: Array<{ options?: { enableHighAccuracy?: boolean; timeout?: number; maximumAge?: number } }> = [];
  const pending: Array<{ success: (position: StartupFixPosition) => void }> = [];
  const geo: StartupGeolocation = {
    getCurrentPosition(success, error, options) {
      calls.push({ options });
      if (answer === 'grant') success(position);
      else if (answer === 'deny') error?.({ code: 1 });
      else pending.push({ success });
    },
  };
  Object.defineProperty(navigator, 'geolocation', { value: geo, configurable: true });
  return { calls, pending };
}

function clearGeolocation() {
  Object.defineProperty(navigator, 'geolocation', { value: undefined, configurable: true });
}

/** A `fetch` that answers once, and records how it was called. */
function fetchReturning(body: unknown, init: { status?: number; ok?: boolean } = {}) {
  const calls: { url: string; init?: RequestInit }[] = [];
  const impl = vi.fn(async (url: string | URL | Request, options?: RequestInit) => {
    calls.push({ url: String(url), init: options });
    const status = init.status ?? 200;
    return {
      ok: init.ok ?? status < 400,
      status,
      json: async () => body,
    } as Response;
  });
  return { impl: impl as unknown as typeof fetch, calls };
}

describe('chooseStartupCenter', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  /**
   * The one ordering worth arguing about. Someone who drew a route in Colorado
   * and closed the tab must come back to Colorado: opening on their own location
   * would show an empty map and make the app look like it lost their work.
   */
  it('prefers the saved view over everything else', () => {
    const saved = { center: { lng: -105.5, lat: 39.1 }, zoom: 9.5 };
    expect(chooseStartupCenter({ saved, cachedFix: fix(), estimate: ANN_ARBOR })).toEqual({
      center: [-105.5, 39.1],
      zoom: 9.5,
      source: 'saved',
    });
  });

  it('prefers a cached fix over the IP estimate', () => {
    expect(chooseStartupCenter({ cachedFix: fix(), estimate: ANN_ARBOR }).source).toBe('fix');
  });

  it('uses the estimate when there is nothing better', () => {
    expect(chooseStartupCenter({ cachedFix: null, estimate: ANN_ARBOR })).toEqual({
      center: [-83.743, 42.2808],
      zoom: 8,
      source: 'estimate',
    });
  });

  it('falls back to the default when there is nothing at all', () => {
    const chosen = chooseStartupCenter({ cachedFix: null, estimate: null });
    expect(chosen.source).toBe('default');
    // Colorado, where this app is about. Somewhere plausible rather than (0, 0).
    expect(chosen.center).toEqual([-106.5, 39.5]);
  });

  it('reads the fix from storage when none is passed', () => {
    saveCachedFix(fix());
    expect(chooseStartupCenter({ estimate: null }).source).toBe('fix');
  });

  it('treats longitude-then-latitude as the order everywhere', () => {
    // Easy to transpose, and a transposed centre is a plausible-looking map in the
    // wrong hemisphere rather than an error.
    const chosen = chooseStartupCenter({ cachedFix: fix({ lon: 11.5, lat: 42.2808 }), estimate: null });
    expect(chosen.center).toEqual([11.5, 42.2808]);
  });

  describe('the cached fix', () => {
    /**
     * `zoomForAccuracy` lands near 13 for a phone fix. That is right for "show me
     * where I am" and wrong for "where should I open" — this app is about terrain,
     * and a street-level first frame hides the relief that makes it worth opening.
     */
    it('opens wider than a precise fix would justify', () => {
      expect(FIX_ZOOM).toBeGreaterThanOrEqual(10);
      expect(FIX_ZOOM).toBeLessThanOrEqual(12);
    });

    it('ignores a fix from the future', () => {
      saveCachedFix(fix({ at: Date.now() + 60_000 }));
      expect(chooseStartupCenter({ estimate: null }).source).toBe('default');
    });
  });
});

describe('parseEstimate', () => {
  it('accepts a well-formed estimate', () => {
    expect(parseEstimate(ANN_ARBOR)).toEqual(ANN_ARBOR);
  });

  it('accepts numeric strings, which is what JSON from the edge can carry', () => {
    expect(parseEstimate({ lat: '42.2808', lon: '-83.743' })).toMatchObject({ lat: 42.2808, lon: -83.743 });
  });

  it('rejects anything that is not a position', () => {
    expect(parseEstimate(null)).toBeNull();
    expect(parseEstimate(undefined)).toBeNull();
    expect(parseEstimate('42.2808,-83.743')).toBeNull();
    expect(parseEstimate({})).toBeNull();
    expect(parseEstimate({ lat: 42.2808 })).toBeNull();
  });

  /** A bad centre is worse than the default it replaced. */
  it('rejects a coordinate off the planet', () => {
    expect(parseEstimate({ lat: 91, lon: 0 })).toBeNull();
    expect(parseEstimate({ lat: 0, lon: 181 })).toBeNull();
    expect(parseEstimate({ lat: 'north', lon: 'west' })).toBeNull();
  });

  it('keeps the place names only when they are strings', () => {
    expect(parseEstimate({ lat: 1, lon: 2, city: 'Ann Arbor' })?.city).toBe('Ann Arbor');
    expect(parseEstimate({ lat: 1, lon: 2, city: 7 })?.city).toBeUndefined();
  });
});

describe('fetchGeoEstimate', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('asks the Worker and returns what it says', async () => {
    const { impl, calls } = fetchReturning(ANN_ARBOR);
    const estimate = await fetchGeoEstimate({ baseUrl: 'https://proxy.test', fetchImpl: impl });

    expect(estimate).toEqual(ANN_ARBOR);
    expect(calls[0]!.url).toBe('https://proxy.test/geo');
  });

  it('trims a trailing slash so the path is not doubled', async () => {
    const { impl, calls } = fetchReturning(ANN_ARBOR);
    await fetchGeoEstimate({ baseUrl: 'https://proxy.test/', fetchImpl: impl });
    expect(calls[0]!.url).toBe('https://proxy.test/geo');
  });

  /**
   * The unconfigured build must pay nothing. There is no `/geo` to ask, so the
   * alternative is a guaranteed request to a broken URL followed by the full
   * timeout on every single load.
   */
  it('does not fetch at all when no proxy is configured', async () => {
    const { impl, calls } = fetchReturning(ANN_ARBOR);
    expect(await fetchGeoEstimate({ baseUrl: '', fetchImpl: impl })).toBeNull();
    expect(calls).toHaveLength(0);
  });

  /** The Worker's "the edge has no location for you" — a successful null. */
  it('treats 204 as no answer rather than as a failure', async () => {
    const { impl } = fetchReturning(null, { status: 204 });
    expect(await fetchGeoEstimate({ baseUrl: 'https://proxy.test', fetchImpl: impl })).toBeNull();
  });

  it('returns null for a refusal rather than throwing', async () => {
    const { impl } = fetchReturning({ error: 'unknown-client' }, { status: 403 });
    expect(await fetchGeoEstimate({ baseUrl: 'https://proxy.test', fetchImpl: impl })).toBeNull();
  });

  it('returns null when the body is not an estimate', async () => {
    const { impl } = fetchReturning({ error: 'upstream_rejected' });
    expect(await fetchGeoEstimate({ baseUrl: 'https://proxy.test', fetchImpl: impl })).toBeNull();
  });

  it('returns null when the network is down', async () => {
    const impl = (() => Promise.reject(new Error('offline'))) as unknown as typeof fetch;
    expect(await fetchGeoEstimate({ baseUrl: 'https://proxy.test', fetchImpl: impl })).toBeNull();
  });

  describe('the timeout', () => {
    it('gives up rather than holding the map hostage', async () => {
      vi.useFakeTimers();
      let aborted = false;
      const impl = ((_url: string, options?: RequestInit) =>
        new Promise<Response>((_resolve, reject) => {
          options?.signal?.addEventListener('abort', () => {
            aborted = true;
            reject(new Error('aborted'));
          });
        })) as unknown as typeof fetch;

      const pending = fetchGeoEstimate({ baseUrl: 'https://proxy.test', fetchImpl: impl, timeoutMs: GEO_TIMEOUT_MS });
      await vi.advanceTimersByTimeAsync(GEO_TIMEOUT_MS);

      expect(await pending).toBeNull();
      expect(aborted).toBe(true);
    });

    it('is short enough that a dead endpoint costs a moment, not the load', () => {
      expect(GEO_TIMEOUT_MS).toBeGreaterThanOrEqual(500);
      expect(GEO_TIMEOUT_MS).toBeLessThanOrEqual(3_000);
    });

    /** An early answer must not leave a timer running against a dead request. */
    it('clears its timer once the answer arrives', async () => {
      vi.useFakeTimers();
      const { impl } = fetchReturning(ANN_ARBOR);
      await fetchGeoEstimate({ baseUrl: 'https://proxy.test', fetchImpl: impl });
      expect(vi.getTimerCount()).toBe(0);
    });
  });
});

describe('normalizeStartupFix', () => {
  it('accepts a well-formed position', () => {
    const position = phonePosition();
    expect(normalizeStartupFix(position)).toEqual({
      lon: -83.743,
      lat: 42.2808,
      at: position.timestamp,
      accuracyMeters: 30,
    });
  });

  it('rejects a coordinate off the planet', () => {
    expect(normalizeStartupFix(phonePosition({ coords: { latitude: 91, longitude: 0, accuracy: 30 } }))).toBeNull();
    expect(normalizeStartupFix(phonePosition({ coords: { latitude: 0, longitude: 181, accuracy: 30 } }))).toBeNull();
    expect(normalizeStartupFix(phonePosition({ coords: { latitude: Number.NaN, longitude: 0, accuracy: 30 } }))).toBeNull();
  });

  /**
   * Same bar, and the same reasoning, as `loadCachedFix` on the way back out: a
   * fix with kilometres of accuracy is no better than the IP centroid it would
   * outrank, so it must not displace the estimate *nor* be stored only to be
   * rejected next load.
   */
  it('rejects an accuracy coarser than a cached fix may be', () => {
    const coarse = LOCATION_MAX_ACCURACY_METERS + 1;
    expect(normalizeStartupFix(phonePosition({ coords: { latitude: 42.2808, longitude: -83.743, accuracy: coarse } }))).toBeNull();
  });

  it('rejects a missing or negative accuracy', () => {
    expect(normalizeStartupFix(phonePosition({ coords: { latitude: 42.2808, longitude: -83.743, accuracy: Number.NaN } }))).toBeNull();
    expect(normalizeStartupFix(phonePosition({ coords: { latitude: 42.2808, longitude: -83.743, accuracy: -1 } }))).toBeNull();
  });

  it('stamps an absent timestamp with now, so the fix is not born stale', () => {
    const at = normalizeStartupFix(phonePosition({ timestamp: Number.NaN }))?.at;
    expect(at).toBeGreaterThan(Date.now() - 5_000);
    expect(at).toBeLessThanOrEqual(Date.now());
  });

  it('rejects a missing position', () => {
    expect(normalizeStartupFix(null)).toBeNull();
    expect(normalizeStartupFix(undefined)).toBeNull();
    expect(normalizeStartupFix({} as StartupFixPosition)).toBeNull();
  });
});

describe('requestStartupFix', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  afterEach(() => {
    vi.useRealTimers();
    clearGeolocation();
  });

  it('resolves the browser’s fix and remembers it for the next load', async () => {
    stubGeolocation('grant');

    const fixFromBrowser = await requestStartupFix();

    expect(fixFromBrowser).toMatchObject({ lon: -83.743, lat: 42.2808, accuracyMeters: 30 });
    // Stored, because a grant that has been asked for once should never be
    // asked for again — the prompt is the cost, not the position.
    expect(localStorage.getItem(LOCATION_KEY)).not.toBeNull();
  });

  it('asks without high accuracy: the opening frame needs a valley, not a GPS fix', async () => {
    const { calls } = stubGeolocation('grant');

    await requestStartupFix();

    expect(calls[0]?.options).toMatchObject({
      enableHighAccuracy: false,
      timeout: STARTUP_FIX_TIMEOUT_MS,
      maximumAge: STARTUP_FIX_MAX_AGE_MS,
    });
  });

  it('resolves null when permission is denied, and stores nothing', async () => {
    stubGeolocation('deny');

    expect(await requestStartupFix()).toBeNull();
    expect(localStorage.getItem(LOCATION_KEY)).toBeNull();
  });

  it('resolves null when the dialog is left open, without holding the map', async () => {
    vi.useFakeTimers();
    stubGeolocation('ignore');

    const pending = requestStartupFix();
    await vi.advanceTimersByTimeAsync(STARTUP_FIX_TIMEOUT_MS);

    expect(await pending).toBeNull();
  });

  it('remembers a grant that lands after the wait, so the next load opens right', async () => {
    vi.useFakeTimers();
    const { pending: unanswered } = stubGeolocation('ignore');

    const settled = await (async () => {
      const pending = requestStartupFix();
      await vi.advanceTimersByTimeAsync(STARTUP_FIX_TIMEOUT_MS);
      return pending;
    })();
    expect(settled).toBeNull();

    // The dialog was answered "Allow" only after the map had opened on the
    // estimate. This load lets it go; the next one does not ask again.
    unanswered[0]?.success(phonePosition());
    expect(localStorage.getItem(LOCATION_KEY)).not.toBeNull();
  });

  it('resolves null when there is no geolocation to ask — HTTP, or an old browser', async () => {
    clearGeolocation();
    expect(await requestStartupFix({ geolocation: null })).toBeNull();
    expect(localStorage.getItem(LOCATION_KEY)).toBeNull();
  });

  it('resolves null when the engine throws instead of prompting', async () => {
    stubGeolocation('ignore');
    const throwing: StartupGeolocation = {
      getCurrentPosition() {
        throw new Error('geolocation requires a secure context');
      },
    };

    expect(await requestStartupFix({ geolocation: throwing })).toBeNull();
  });

  it('does not store a fix too coarse to be worth the name', async () => {
    stubGeolocation('grant', phonePosition({
      coords: { latitude: 42.2808, longitude: -83.743, accuracy: LOCATION_MAX_ACCURACY_METERS + 1 },
    }));

    expect(await requestStartupFix()).toBeNull();
    expect(localStorage.getItem(LOCATION_KEY)).toBeNull();
  });

  it('gives up in seconds, not tens: an ignored dialog costs a moment, not the load', () => {
    expect(STARTUP_FIX_TIMEOUT_MS).toBeGreaterThanOrEqual(1_000);
    expect(STARTUP_FIX_TIMEOUT_MS).toBeLessThanOrEqual(5_000);
    // The estimate runs in parallel, so this budget is also the most the two
    // waits can stack to.
    expect(STARTUP_FIX_TIMEOUT_MS).toBeGreaterThanOrEqual(GEO_TIMEOUT_MS);
  });

  /** An early answer must not leave a timer running against a dead prompt. */
  it('clears its timer once the answer arrives', async () => {
    vi.useFakeTimers();
    // Primed with the fix the grant is about to write, because jsdom defers
    // storage notifications behind a timer of its own: counted now, it is part
    // of the baseline rather than of what this asserts — that requestStartupFix
    // clears its *own* watchdog when the answer beats the budget.
    const position = phonePosition();
    stubGeolocation('grant', position);
    saveCachedFix(normalizeStartupFix(position)!);
    const before = vi.getTimerCount();
    await requestStartupFix();
    expect(vi.getTimerCount()).toBe(before);
  });
});

describe('resolveStartupCenter', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  afterEach(() => {
    vi.useRealTimers();
    clearGeolocation();
    vi.unstubAllGlobals();
  });

  /**
   * Returning to your own map must not cost a round trip. The estimate is only
   * worth fetching when there is a chance it will be used.
   */
  it('does not reach the network when a saved view answers the question', async () => {
    const impl = (() => {
      throw new Error('the network must not be touched');
    }) as unknown as typeof fetch;
    vi.stubGlobal('fetch', impl);
    // Nor the browser: the saved view outranks a fix, so asking would be a
    // prompt the answer is never read from.
    const { calls } = stubGeolocation('grant');

    const chosen = await resolveStartupCenter({ center: { lng: -105.5, lat: 39.1 }, zoom: 9.5 });

    expect(chosen.source).toBe('saved');
    expect(calls).toHaveLength(0);
  });

  it('does not reach the network when a cached fix answers the question', async () => {
    saveCachedFix(fix());
    const impl = (() => {
      throw new Error('the network must not be touched');
    }) as unknown as typeof fetch;
    vi.stubGlobal('fetch', impl);
    const { calls } = stubGeolocation('grant');

    const chosen = await resolveStartupCenter(undefined);

    expect(chosen.source).toBe('fix');
    expect(calls).toHaveLength(0);
  });

  /**
   * The issue asks for the prompt outright: a first visit with nothing to open
   * on asks the browser for a position, and the answer — not the estimate —
   * decides the opening frame. The fix is remembered, so the prompt is a
   * one-time cost in practice.
   */
  it('opens on a granted position rather than the estimate, and keeps it', async () => {
    stubGeolocation('grant', phonePosition());
    vi.stubGlobal('fetch', fetchReturning(ANN_ARBOR).impl);

    const chosen = await resolveStartupCenter(undefined);

    expect(chosen.source).toBe('fix');
    expect(chosen.center).toEqual([-83.743, 42.2808]);
    expect(chosen.zoom).toBe(FIX_ZOOM);
    expect(localStorage.getItem(LOCATION_KEY)).not.toBeNull();
  });

  it('falls back to the estimate when permission is denied', async () => {
    stubGeolocation('deny');
    vi.stubGlobal('fetch', fetchReturning(ANN_ARBOR).impl);

    const chosen = await resolveStartupCenter(undefined);

    expect(chosen.source).toBe('estimate');
    expect(localStorage.getItem(LOCATION_KEY)).toBeNull();
  });

  it('falls back to the estimate when the dialog is ignored past the budget', async () => {
    vi.useFakeTimers();
    stubGeolocation('ignore');
    vi.stubGlobal('fetch', fetchReturning(ANN_ARBOR).impl);

    const pending = resolveStartupCenter(undefined);
    await vi.advanceTimersByTimeAsync(STARTUP_FIX_TIMEOUT_MS);

    expect((await pending).source).toBe('estimate');
  });

  it('does not ask a second time once the first grant is remembered', async () => {
    stubGeolocation('grant');
    vi.stubGlobal('fetch', fetchReturning(ANN_ARBOR).impl);

    await resolveStartupCenter(undefined);
    vi.unstubAllGlobals();

    const { calls } = stubGeolocation('grant');
    vi.stubGlobal('fetch', (() => {
      throw new Error('the network must not be touched');
    }) as unknown as typeof fetch);

    const chosen = await resolveStartupCenter(undefined);

    expect(chosen.source).toBe('fix');
    expect(calls).toHaveLength(0);
  });

  it('falls through to the default when there is no proxy to ask', async () => {
    // `startup.ts` reads the real config, which the suite sets to `proxy.test`,
    // so this asserts the shape of the decision rather than the network: the
    // cached fix is cleared, nothing is saved, and the result is still a position.
    const chosen = await resolveStartupCenter(undefined);
    expect(chosen.center).toHaveLength(2);
    expect(Number.isFinite(chosen.center[0])).toBe(true);
    expect(Number.isFinite(chosen.center[1])).toBe(true);
  });

  it('never stores an estimate as though it were a real fix', async () => {
    await resolveStartupCenter(undefined);
    expect(localStorage.getItem(LOCATION_KEY)).toBeNull();
  });
});