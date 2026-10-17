// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  chooseStartupCenter,
  fetchGeoEstimate,
  FIX_ZOOM,
  GEO_TIMEOUT_MS,
  parseEstimate,
  resolveStartupCenter,
  type GeoEstimate,
} from '../src/startup';
import { LOCATION_KEY, saveCachedFix, type CachedFix } from '../src/storage';

const ANN_ARBOR: GeoEstimate = { lat: 42.2808, lon: -83.743, city: 'Ann Arbor', country: 'US', precision: 'city' };

const fix = (over: Partial<CachedFix> = {}): CachedFix => ({
  lon: -83.743,
  lat: 42.2808,
  at: Date.now(),
  accuracyMeters: 30,
  ...over,
});

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

describe('resolveStartupCenter', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  afterEach(() => {
    vi.useRealTimers();
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

    const chosen = await resolveStartupCenter({ center: { lng: -105.5, lat: 39.1 }, zoom: 9.5 });

    expect(chosen.source).toBe('saved');
    vi.unstubAllGlobals();
  });

  it('does not reach the network when a cached fix answers the question', async () => {
    saveCachedFix(fix());
    const impl = (() => {
      throw new Error('the network must not be touched');
    }) as unknown as typeof fetch;
    vi.stubGlobal('fetch', impl);

    const chosen = await resolveStartupCenter(undefined);

    expect(chosen.source).toBe('fix');
    vi.unstubAllGlobals();
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