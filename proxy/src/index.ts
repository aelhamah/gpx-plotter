import { authorize, countRequest, withinQuota, type QuotaState } from './authorize';
import { isAllowedPath, sanitizeUpstreamResponse, upstreamURL } from './upstream';

/**
 * A pass-through proxy in front of MapTiler.
 *
 * ## Why
 *
 * The key currently ships inside the app bundle, where anyone can read it out of
 * a downloaded `.ipa` and spend somebody else's account. This puts the key in a
 * Worker secret instead, and hands out only the Worker URL.
 *
 * ## Caching
 *
 * **This proxy does not cache, and must not, until MapTiler says otherwise in
 * writing.** MapTiler's terms prohibit bulk tile downloading without an
 * agreement, and caching tile bodies at the edge is bulk downloading — the
 * request pattern is indistinguishable from scraping, which is what the clause
 * exists to prevent. Passing a request through and forgetting it is not bulk
 * downloading, so the proxy is useful today under the terms as they stand.
 *
 * The switch is one guarded block in `fetch` and a `CACHE_TILES` variable. It is
 * written as a flag rather than left implicit so that turning it on is a
 * deliberate act with a date attached, rather than a `caches.default.match`
 * appearing during an optimisation.
 *
 * The client keeps its own on-disk cache. That is where a tile is meant to be
 * remembered: on the user's device, under the user's control.
 */
export interface Env {
  /** MapTiler API key. A secret: `wrangler secret put MAPTILER_KEY`. */
  MAPTILER_KEY: string;
  /** Exact `User-Agent` values allowed to spend the key, comma separated. */
  ALLOWED_CLIENTS: string;
  /** Requests per client per UTC day. */
  DAILY_QUOTA: string;
  /** Where to forward to. `https://api.maptiler.com` in production. */
  UPSTREAM?: string;
  /** Set to `"true"` only once MapTiler has agreed in writing. See §Caching. */
  CACHE_TILES?: string;
  /** One Durable Object per client token, holding that client's day. */
  QUOTA: DurableObjectNamespace;
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    // Unauthenticated on purpose: it reveals nothing about the key, and a deploy
    // that 404s on its own health check is worse than one that leaks a boolean.
    if (url.pathname === '/__health') return json({ ok: true });

    // MapLibre issues HEADs while probing a source. Forwarding them is cheaper
    // than refusing them, which would surface as a failed style load.
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return json({ error: 'method_not_allowed' }, 405);
    }

    // An allowlist, so an unknown or future endpoint cannot be proxied by
    // accident. See §ALLOWED_PREFIXES.
    if (!isAllowedPath(url.pathname)) return json({ error: 'not_proxied' }, 404);

    const today = todayUTC();
    const clients = parseClients(env.ALLOWED_CLIENTS);
    const limit = Number(env.DAILY_QUOTA);

    // Authorize on the identity alone first, so an unknown client costs one
    // Durable Object round trip and no upstream traffic.
    const identity = authorize(request.headers.get('user-agent'), clients, { day: today, count: 0 }, limit, today);
    if (!identity.allowed) return json({ error: identity.reason }, identity.status);

    const quota = env.QUOTA.get(env.QUOTA.idFromName(identity.token));
    const spent = await quota.fetch(`https://quota/check?day=${today}&limit=${limit}`);
    if (spent.status !== 200) {
      const state = (await spent.json()) as { day: string; count: number };
      return json({ error: 'quota_exceeded', day: state.day, count: state.count, limit }, 429);
    }

    const upstream = new Request(
      upstreamURL(env.UPSTREAM ?? 'https://api.maptiler.com', url.pathname, url.search, env.MAPTILER_KEY),
      { method: request.method, headers: upstreamHeaders(request.headers, identity.token) }
    );

    const response = await fetch(upstream);
    const safe = sanitizeUpstreamResponse(response);

    // Charged only on a real upstream answer. A client that is being refused
    // cannot spend its own allowance and lock itself out of the diagnostic that
    // would explain why.
    ctx.waitUntil(quota.fetch(`https://quota/spend?day=${today}&limit=${limit}`));

    if (safe.ok && env.CACHE_TILES === 'true' && isCacheable(url.pathname)) {
      // §Caching. Do not enable without a written agreement from MapTiler.
      ctx.waitUntil(caches.default.put(new Request(upstream.url), safe.clone()));
    }

    return safe;
  },
};

/**
 * One client's day.
 *
 * Named by the client token, so every request from one app counts together and
 * two apps cannot spend each other's allowance. The decision arithmetic lives in
 * `authorize.ts` and is unit tested; this class is only storage and a transport
 * for it.
 */
export class QuotaCounter {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const day = url.searchParams.get('day') ?? todayUTC();
    const limit = Number(url.searchParams.get('limit') ?? '0');
    const read = async (): Promise<QuotaState> =>
      ((await this.state.storage.get('quota')) as QuotaState | undefined) ?? { day, count: 0 };

    if (url.pathname.endsWith('/spend')) {
      // Serialised by the Durable Object itself. One transaction per client, so
      // two concurrent requests cannot both read the same count and both conclude
      // there is room for one more.
      await this.state.blockConcurrencyWhile(async () => {
        await this.state.storage.put('quota', countRequest(await read(), day));
      });
      return json({ day, ok: true });
    }

    const stored = await read();
    if (!withinQuota(stored, limit, day)) {
      // 429 from the counter, which the entry point turns into the client's 429
      // with the allowance attached.
      return new Response(JSON.stringify(stored), {
        status: 429,
        headers: { 'content-type': 'application/json' },
      });
    }
    return json({ day, count: stored.count });
  }
}

// MARK: - Helpers

/** Forwarded request headers: the identity, and nothing that could carry a key. */
function upstreamHeaders(incoming: Headers, token: string): Headers {
  const headers = new Headers();
  // The client's own token, byte for byte. Rewriting this breaks the MapTiler
  // key allowlist — the mechanism §5.1 of the plan relies on — so the value that
  // authenticated here is the value forwarded.
  headers.set('user-agent', token);
  const accept = incoming.get('accept');
  if (accept) headers.set('accept', accept);
  // Deliberately not forwarded: `cookie`, `authorization`, `accept-encoding`.
  // Cloudflare handles encoding at the edge, and forwarding `accept-encoding`
  // buys a decompress step and nothing else.
  return headers;
}

/** Only raster tiles are ever candidates for caching. */
function isCacheable(pathname: string): boolean {
  return pathname.startsWith('/tiles/');
}

function todayUTC(): string {
  return new Date().toISOString().slice(0, 10);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });
}

/** Split the comma-separated allowlist, ignoring the spaces people put in it. */
export function parseClients(raw: string | undefined): string[] {
  return (raw ?? '')
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}