import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import worker, { type Env } from '../src/index';

/**
 * The wiring, not the arithmetic.
 *
 * `authorize.ts` and `upstream.ts` are unit tested on their own. What is left is
 * the order things happen in, and the order is where the interesting failures
 * live: a key fetched upstream before the caller has been identified, a quota
 * charged for a request that was refused, an error body relayed with the key in
 * it. So this drives the real entry point with a stubbed network and a stubbed
 * Durable Object, and asserts on what left the building.
 */

const TOKEN = 'GPXNav (iOS; com.aelhamah.GPXNav)';
const SITE = 'https://aelhamah.github.io';
const BROWSER_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)';
const KEY = 'super_secret_maptiler_key';
const TODAY = new Date().toISOString().slice(0, 10);

/** Every request the Worker made upstream, in order. */
let upstreamCalls: Request[] = [];
/** What the Durable Object says about the allowance. */
let quotaStatus = 200;
let quotaBody = { day: TODAY, count: 0 };

/** Names handed to `idFromName`, in order, so the quota split is assertable. */
let quotaNames: string[] = [];
/** Limits handed to the counter, in order. Same reason. */
let quotaLimits: number[] = [];

/**
 * A Durable Object namespace that behaves like the real one about the limit.
 *
 * The first version of this stub ignored the `limit` in the query and just
 * replayed a canned status, which meant a test could assert that a browser was
 * billed at the web rate and pass without the rate ever being checked. It now
 * compares the stored count against the limit it was actually given.
 */
const fakeNamespace = {
  idFromName: (name: string) => {
    quotaNames.push(name);
    return { name };
  },
  get: () => ({
    fetch: async (request: Request) => {
      if (quotaStatus !== 200) return new Response(JSON.stringify(quotaBody), { status: quotaStatus });
      const url = new URL(typeof request === 'string' ? request : request.url);
      const limit = Number(url.searchParams.get('limit'));
      quotaLimits.push(limit);
      const over = quotaBody.day === TODAY && quotaBody.count >= limit;
      return new Response(JSON.stringify(quotaBody), { status: over ? 429 : 200 });
    },
  }),
} as unknown as Env['QUOTA'];

function env(overrides: Partial<Env> = {}): Env {
  return {
    MAPTILER_KEY: KEY,
    ALLOWED_CLIENTS: TOKEN,
    ALLOWED_ORIGINS: SITE,
    DAILY_QUOTA: '10',
    WEB_DAILY_QUOTA: '500',
    UPSTREAM: 'https://api.maptiler.com',
    QUOTA: fakeNamespace,
    ...overrides,
  };
}

/** Runs the entry point and hands back the response plus the settled waits. */
async function invoke(request: Request, environment: Env = env()) {
  const waits: Promise<unknown>[] = [];
  const ctx = { waitUntil: (p: Promise<unknown>) => waits.push(p), passThroughOnException: () => {} };
  const response = await worker.fetch(request, environment, ctx as unknown as ExecutionContext);
  await Promise.allSettled(waits);
  return response;
}

function get(path: string, userAgent: string | null = TOKEN, origin: string | null = null): Request {
  const headers: Record<string, string> = {};
  if (userAgent !== null) headers['user-agent'] = userAgent;
  if (origin !== null) headers.origin = origin;
  return new Request(`https://proxy.example${path}`, { headers });
}

beforeEach(() => {
  upstreamCalls = [];
  quotaNames = [];
  quotaLimits = [];
  quotaStatus = 200;
  quotaBody = { day: TODAY, count: 0 };
  vi.stubGlobal('fetch', async (input: Request) => {
    upstreamCalls.push(input);
    return new Response('tile-bytes', { status: 200, headers: { 'content-type': 'image/png' } });
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('the Worker', () => {
  it('answers its health check without credentials', async () => {
    const response = await invoke(get('/__health', null));
    expect(response.status).toBe(200);
    expect(upstreamCalls).toHaveLength(0);
  });

  it('refuses an unknown client before touching the network', async () => {
    const response = await invoke(get('/maps/outdoor-v2/style.json', 'SomeoneElse/1.0'));
    expect(response.status).toBe(403);
    // The point of the test. If this ever becomes 1, the key is being spent on
    // requests from strangers.
    expect(upstreamCalls).toHaveLength(0);
  });

  it('refuses a missing user-agent before touching the network', async () => {
    const response = await invoke(get('/maps/outdoor-v2/style.json', null));
    expect(response.status).toBe(403);
    expect(upstreamCalls).toHaveLength(0);
  });

  it('refuses a user-agent that only looks right, before touching the network', async () => {
    const response = await invoke(get('/maps/outdoor-v2/style.json', `${TOKEN} MapLibre/6.31.0`));
    expect(response.status).toBe(403);
    expect(upstreamCalls).toHaveLength(0);
  });

  it('refuses a path that is not proxied', async () => {
    const response = await invoke(get('/admin/keys'));
    expect(response.status).toBe(404);
    expect(upstreamCalls).toHaveLength(0);
  });

  it('refuses a method that is not a read', async () => {
    const response = await invoke(
      new Request('https://proxy.example/maps/x/style.json', { method: 'POST' })
    );
    expect(response.status).toBe(405);
    expect(upstreamCalls).toHaveLength(0);
  });

  it('forwards a good request with the key and the identity intact', async () => {
    const response = await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png'));
    expect(response.status).toBe(200);
    expect(await response.text()).toBe('tile-bytes');
    expect(upstreamCalls).toHaveLength(1);

    const sent = upstreamCalls[0]!;
    // The key goes upstream and only upstream.
    expect(new URL(sent.url).searchParams.get('key')).toBe(KEY);
    // Byte for byte, because the MapTiler allowlist matches the whole header.
    expect(sent.headers.get('user-agent')).toBe(TOKEN);
  });

  it('never puts the key in a response the client can read', async () => {
    const response = await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png'));
    const body = await response.text();
    expect(body).not.toContain(KEY);
    for (const [, value] of response.headers) expect(value).not.toContain(KEY);
  });

  it('does not forward cookies or authorization upstream', async () => {
    const request = new Request('https://proxy.example/maps/x/style.json', {
      headers: {
        'user-agent': TOKEN,
        cookie: 'session=abc',
        authorization: 'Bearer nope',
        'accept-encoding': 'gzip',
      },
    });
    await invoke(request);
    const sent = upstreamCalls[0]!;
    expect(sent.headers.get('cookie')).toBeNull();
    expect(sent.headers.get('authorization')).toBeNull();
    expect(sent.headers.get('accept-encoding')).toBeNull();
  });

  it('serves a Head request rather than treating it as an attack', async () => {
    const request = new Request('https://proxy.example/maps/x/style.json', {
      method: 'HEAD',
      headers: { 'user-agent': TOKEN },
    });
    const response = await invoke(request);
    expect(response.status).toBe(200);
    expect(upstreamCalls[0]!.method).toBe('HEAD');
  });

  it('returns 429 with the allowance when the client is out', async () => {
    quotaStatus = 429;
    quotaBody = { day: TODAY, count: 10 };
    const response = await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png'));
    expect(response.status).toBe(429);
    // Not charged, and more to the point not forwarded.
    expect(upstreamCalls).toHaveLength(0);
    expect(await response.json()).toMatchObject({ error: 'quota_exceeded', limit: 10, count: 10 });
  });

  it('hides the key when the upstream refuses', async () => {
    vi.stubGlobal('fetch', async () => new Response(`bad request, url had key=${KEY}`, { status: 400 }));
    const response = await invoke(get('/maps/nope/style.json'));
    expect(response.status).toBe(502);
    const body = await response.text();
    expect(body).not.toContain(KEY);
    expect(JSON.parse(body)).toEqual({ error: 'upstream_rejected', status: 400 });
  });

  /**
   * Both directions, because both matter.
   *
   * The default has to not cache, and `caches` does not exist in Node — so a
   * `caches.default.put` on the default path throws and fails this test rather
   * than quietly doing nothing.
   *
   * The opt-in has to *work*, not merely be present. §Enabling caching in the
   * README tells someone to flip a flag; if that line throws on first use, they
   * find out at the moment they are relying on it, in production, which is the
   * worst possible way to discover a one-line switch was never run.
   */
  it('caches nothing by default, and caches only when the flag is set', async () => {
    const puts: Request[] = [];
    vi.stubGlobal('caches', {
      default: {
        put: async (request: Request) => {
          puts.push(request);
          return undefined;
        },
      },
    });

    await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png'), env({ CACHE_TILES: 'false' }));
    expect(puts).toHaveLength(0);

    const response = await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png'), env({ CACHE_TILES: 'true' }));
    expect(puts).toHaveLength(1);
    // And it caches the upstream URL, key and all, because that is the only
    // address that works without re-adding the secret.
    expect(new URL(puts[0]!.url).searchParams.get('key')).toBe(KEY);
    // The response still advertises no store, so the *client's* cache and the
    // edge's are separate decisions.
    expect(response.headers.get('x-proxy-cache')).toBe('disabled');
  });

  /** Styles and geocoding are never tile bodies, so never cache candidates. */
  it('does not treat a style or a geocode as a cacheable tile', async () => {
    const puts: Request[] = [];
    vi.stubGlobal('caches', {
      default: {
        put: async (request: Request) => {
          puts.push(request);
          return undefined;
        },
      },
    });
    await invoke(get('/maps/outdoor-v2/style.json'), env({ CACHE_TILES: 'true' }));
    await invoke(get('/geocoding/x.json'), env({ CACHE_TILES: 'true' }));
    expect(puts).toHaveLength(0);
  });

  /**
   * The whole reason this Worker exists, end to end.
   *
   * `sanitizeUpstreamResponse` already stops the key leaving in a header or an
   * error body, and it still passed with a style full of them — because in a
   * style the key is in the *body*, inside a URL the renderer is about to
   * fetch. So this drives the real entry point with a realistic MapTiler style
   * and asserts on what the client actually receives.
   */
  it('serves a style with the key taken out of its body', async () => {
    const upstreamStyle = JSON.stringify({
      version: 8,
      glyphs: `https://api.maptiler.com/fonts/{fontstack}/{range}.pbf?key=${KEY}`,
      sources: {
        outdoor: { url: `https://api.maptiler.com/tiles/outdoor/tiles.json?key=${KEY}` },
        'terrain-rgb': { url: `https://api.maptiler.com/tiles/terrain-rgb-v2/tiles.json?key=${KEY}` },
      },
    });
    vi.stubGlobal('fetch', async () =>
      new Response(upstreamStyle, { status: 200, headers: { 'content-type': 'application/json' } })
    );

    const response = await invoke(get('/maps/outdoor-v2/style.json'));
    const body = await response.text();

    expect(response.status).toBe(200);
    expect(body).not.toContain(KEY);

    const style = JSON.parse(body) as { glyphs: string; sources: Record<string, { url: string }> };
    // Every source now points back at this Worker, which is where the key gets
    // added — so following them still works, and still never reveals the key.
    expect(style.sources.outdoor!.url).toBe('https://proxy.example/tiles/outdoor/tiles.json');
    expect(style.sources['terrain-rgb']!.url).toBe('https://proxy.example/tiles/terrain-rgb-v2/tiles.json');
    expect(style.glyphs).toBe('https://proxy.example/fonts/{fontstack}/{range}.pbf');
  });

  /** A TileJSON is the second hop, and the place a naive fix stops working. */
  it('serves a TileJSON with the key taken out of its tile list', async () => {
    vi.stubGlobal('fetch', async () =>
      new Response(
        JSON.stringify({ tiles: [`https://api.maptiler.com/tiles/terrain-rgb-v2/{z}/{x}/{y}.png?key=${KEY}`] }),
        { status: 200, headers: { 'content-type': 'application/json' } }
      )
    );

    const response = await invoke(get('/tiles/terrain-rgb-v2/tiles.json'));
    const body = await response.text();
    expect(body).not.toContain(KEY);
    // Byte-identical placeholders: `{z}` must survive as `{z}`. Percent-encoded
    // to `%7Bz%7D` it still contains no key, so a leak-only test passes while
    // every single tile request silently 404s in the real app.
    expect(JSON.parse(body)).toEqual({
      tiles: ['https://proxy.example/tiles/terrain-rgb-v2/{z}/{x}/{y}.png'],
    });
  });

  /** A tile body is binary. Parsing it would corrupt it. */
  it('passes a tile body through untouched', async () => {
    const bytes = new Uint8Array([0, 1, 2, 250, 251, 252]);
    vi.stubGlobal('fetch', async () => new Response(bytes, { headers: { 'content-type': 'image/webp' } }));

    const response = await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png'));
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(bytes);
  });

  /** A HEAD on a style has no body, so there is nothing to parse. */
  it('serves a HEAD on a style without trying to rewrite a body', async () => {
    const request = new Request('https://proxy.example/maps/x/style.json', {
      method: 'HEAD',
      headers: { 'user-agent': TOKEN },
    });
    const response = await invoke(request);
    expect(response.status).toBe(200);
  });

  /**
   * If MapTiler ever sends something unparseable, the map should fail visibly
   * rather than load a style with no sources and no error.
   */
  it('passes an unparseable document through rather than emptying it', async () => {
    vi.stubGlobal('fetch', async () =>
      new Response('<html>not json</html>', { status: 200, headers: { 'content-type': 'application/json' } })
    );
    const response = await invoke(get('/maps/x/style.json'));
    expect(response.status).toBe(200);
    expect(await response.text()).toBe('<html>not json</html>');
  });
  // MARK: - The browser build

  describe('a browser', () => {
    it('is served when it presents an allowlisted Origin', async () => {
      const response = await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png', BROWSER_UA, SITE));
      expect(response.status).toBe(200);
      expect(upstreamCalls).toHaveLength(1);
      // It is told so, which is the other half of being served: without this the
      // response is fetched, discarded, and the map is blank.
      expect(response.headers.get('access-control-allow-origin')).toBe(SITE);
    });

    it('is refused when it presents an origin that is not allowlisted', async () => {
      const response = await invoke(
        get('/tiles/terrain-rgb-v2/1/2/3.png', BROWSER_UA, 'https://evil.test')
      );
      expect(response.status).toBe(403);
      expect(upstreamCalls).toHaveLength(0);
    });

    /**
     * Never `*`. That would make the proxy readable by every page on the
     * internet, which is the exact opposite of an origin allowlist.
     */
    it('is never granted a wildcard origin', async () => {
      const response = await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png', BROWSER_UA, SITE));
      expect(response.headers.get('access-control-allow-origin')).not.toBe('*');
      // And an unknown origin gets no permission at all.
      const refused = await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png', BROWSER_UA, 'https://evil.test'));
      expect(refused.headers.get('access-control-allow-origin')).toBeNull();
    });

    /**
     * The case that made this work necessary: a browser cannot read an error it
     * was not given permission to read, so an unlabelled 429 arrives in the UI
     * as an unexplained CORS failure instead of "quota exceeded".
     */
    it('can read its own refusals', async () => {
      quotaStatus = 429;
      quotaBody = { day: TODAY, count: 500 };
      const response = await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png', BROWSER_UA, SITE));
      expect(response.status).toBe(429);
      expect(response.headers.get('access-control-allow-origin')).toBe(SITE);
      expect(await response.json()).toMatchObject({ error: 'quota_exceeded', limit: 500 });
    });

    it('can read a 403 it caused', async () => {
      const response = await invoke(get('/admin/keys', BROWSER_UA, SITE));
      expect(response.status).toBe(404);
      expect(response.headers.get('access-control-allow-origin')).toBe(SITE);
    });

    /**
     * MapLibre GL JS sends no custom headers, so nothing it does is a preflighted
     * request today. But a preflight answered 405 makes the browser report CORS
     * for every request after it, turning one unsupported call into a blank map.
     */
    it('answers a preflight without spending upstream or quota', async () => {
      const request = new Request('https://proxy.example/maps/x/style.json', {
        method: 'OPTIONS',
        headers: { origin: SITE, 'access-control-request-method': 'GET' },
      });
      const response = await invoke(request);
      expect(response.status).toBe(204);
      expect(response.headers.get('access-control-allow-origin')).toBe(SITE);
      expect(response.headers.get('access-control-allow-methods')).toContain('GET');
      expect(upstreamCalls).toHaveLength(0);
      expect(quotaNames).toHaveLength(0);
    });

    /**
     * Shared Cloudflare cache in front of this Worker. Without `Vary: Origin` a
     * response built for one allowlisted origin can be served to another.
     */
    it('is told the response varies by origin', async () => {
      const response = await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png', BROWSER_UA, SITE));
      expect(response.headers.get('vary')).toContain('Origin');
    });

    /** Native sends no Origin, so it is not subject to CORS and must not be granted it. */
    it('leaves a native client with no CORS headers at all', async () => {
      const response = await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png'));
      expect(response.status).toBe(200);
      expect(response.headers.get('access-control-allow-origin')).toBeNull();
    });

    it('is billed against its own allowance, not the native one', async () => {
      // 10 spent against a native allowance of 10, which is exactly exhausted,
      // and against a web allowance of 500, which it is not.
      quotaBody = { day: TODAY, count: 10 };
      const response = await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png', BROWSER_UA, SITE));
      expect(response.status).toBe(200);
      // Both the check and the spend are at the web rate; a split between them
      // would let a browser pass the check and then be charged elsewhere.
      expect(quotaLimits).toEqual([500, 500]);
      // Namespaced, so the two can never spend each other's bucket.
      expect(quotaNames).toEqual([`web:${SITE}`]);
    });

    it('gives a native client its own separately named bucket', async () => {
      await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png'));
      expect(quotaNames).toEqual([`native:${TOKEN}`]);
      expect(quotaLimits).toEqual([10, 10]);
    });

    /** A native client really is cut off at the smaller figure. */
    it('still holds the native client to the native allowance', async () => {
      quotaBody = { day: TODAY, count: 10 };
      const response = await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png'));
      expect(response.status).toBe(429);
      expect(await response.json()).toMatchObject({ limit: 10 });
    });

    /**
     * The MapTiler key's allowlist is one exact string, and keeping it that way
     * is the reason the key can stay out of every client.
     */
    it('leaves upstream as the allowlisted native identity', async () => {
      await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png', BROWSER_UA, SITE));
      expect(upstreamCalls[0]!.headers.get('user-agent')).toBe(TOKEN);
    });

    /** Forwarded so MapTiler's own referrer restriction is not bypassed by the hop. */
    it('forwards its Origin upstream', async () => {
      await invoke(get('/tiles/terrain-rgb-v2/1/2/3.png', BROWSER_UA, SITE));
      expect(upstreamCalls[0]!.headers.get('origin')).toBe(SITE);
    });

    it('still never sees the key', async () => {
      const response = await invoke(get('/maps/outdoor-v2/style.json', BROWSER_UA, SITE));
      const body = await response.text();
      expect(body).not.toContain(KEY);
      for (const [, value] of response.headers) expect(value).not.toContain(KEY);
    });
  });
});

/**
 * A request carrying edge geo properties, which `Request` has no field for.
 *
 * `wrangler dev` and the test runtime both leave `cf` undefined, so the
 * "Cloudflare did not say" path is the one that runs by default here — which is
 * exactly the path that would otherwise go untested.
 */
function geoRequest(
  cf: Record<string, unknown> | undefined,
  userAgent: string | null = BROWSER_UA,
  origin: string | null = SITE
): Request {
  const request = get('/geo', userAgent, origin);
  Object.defineProperty(request, 'cf', { value: cf, configurable: true });
  return request;
}

const ANN_ARBOR = { latitude: '42.2808', longitude: '-83.7430', city: 'Ann Arbor', country: 'US' };

describe('/geo', () => {
  it('answers an allowed browser with the estimate from the edge', async () => {
    const response = await invoke(geoRequest(ANN_ARBOR));
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({ lat: 42.2808, lon: -83.743, precision: 'city' });
  });

  it('tells the browser it is allowed to read the answer', async () => {
    // Without this the response is fetched, dropped, and the caller falls back to
    // its default — the same failure the tile CORS work fixed for tiles.
    const response = await invoke(geoRequest(ANN_ARBOR));
    expect(response.headers.get('access-control-allow-origin')).toBe(SITE);
  });

  /** There is no upstream for this: the answer arrived with the request. */
  it('never touches MapTiler', async () => {
    await invoke(geoRequest(ANN_ARBOR));
    expect(upstreamCalls).toHaveLength(0);
  });

  /**
   * The quota exists to stop clients spending MapTiler's money and this spends
   * none. Charging it would buy nothing and cost a Durable Object round trip on
   * the critical path of first paint.
   */
  it('is not charged to the quota', async () => {
    await invoke(geoRequest(ANN_ARBOR));
    expect(quotaNames).toHaveLength(0);
    expect(quotaLimits).toHaveLength(0);
  });

  it('answers a native client too', async () => {
    const response = await invoke(geoRequest(ANN_ARBOR, TOKEN, null));
    expect(response.status).toBe(200);
  });

  it('refuses a caller that is not on the allowlist', async () => {
    const response = await invoke(geoRequest(ANN_ARBOR, BROWSER_UA, 'https://aelhamah.github.io.evil.test'));
    expect(response.status).toBe(403);
    expect(upstreamCalls).toHaveLength(0);
    expect(quotaNames).toHaveLength(0);
  });

  it('refuses a caller that presents nothing', async () => {
    const response = await invoke(geoRequest(ANN_ARBOR, null, null));
    expect(response.status).toBe(403);
  });

  /**
   * 204 rather than a JSON `null`: "no estimate" is a successful answer to a
   * question that was asked, and a client waiting on first paint should not have
   * to parse a body to discover it should use its own default.
   */
  it('answers 204 when the edge has no location for the caller', async () => {
    const response = await invoke(geoRequest(undefined));
    expect(response.status).toBe(204);
    expect(response.headers.get('access-control-allow-origin')).toBe(SITE);
  });

  it('answers 204 when the edge sends a half position', async () => {
    const response = await invoke(geoRequest({ latitude: '42.2808' }));
    expect(response.status).toBe(204);
  });

  it('is not reachable by prefix, like every other path here', async () => {
    const response = await invoke(get('/geo/anything', BROWSER_UA, SITE));
    expect(response.status).toBe(404);
  });

  it('does not expose the key', async () => {
    const response = await invoke(geoRequest(ANN_ARBOR));
    const body = await response.text();
    expect(body).not.toContain(KEY);
    for (const [, value] of response.headers) expect(value).not.toContain(KEY);
  });
});
