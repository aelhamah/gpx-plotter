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
const KEY = 'super_secret_maptiler_key';
const TODAY = new Date().toISOString().slice(0, 10);

/** Every request the Worker made upstream, in order. */
let upstreamCalls: Request[] = [];
/** What the Durable Object says about the allowance. */
let quotaStatus = 200;
let quotaBody = { day: TODAY, count: 0 };

/** A Durable Object namespace that answers from `quotaStatus`. */
const fakeNamespace = {
  idFromName: (name: string) => ({ name }),
  get: () => ({
    fetch: async () => new Response(JSON.stringify(quotaBody), { status: quotaStatus }),
  }),
} as unknown as Env['QUOTA'];

function env(overrides: Partial<Env> = {}): Env {
  return {
    MAPTILER_KEY: KEY,
    ALLOWED_CLIENTS: TOKEN,
    DAILY_QUOTA: '10',
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

function get(path: string, userAgent: string | null = TOKEN): Request {
  return new Request(`https://proxy.example${path}`, {
    headers: userAgent === null ? {} : { 'user-agent': userAgent },
  });
}

beforeEach(() => {
  upstreamCalls = [];
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
});