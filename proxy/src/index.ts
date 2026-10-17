import {
  authorize,
  countRequest,
  identifyOrigin,
  withinQuota,
  type ClientKind,
  type QuotaState,
} from './authorize';
import {
  isAllowedPath,
  isTileDocument,
  rewriteTileDocument,
  sanitizeUpstreamResponse,
  upstreamURL,
} from './upstream';

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
 *
 * ## Two kinds of caller
 *
 * The native app authenticates on `User-Agent`; the browser build authenticates
 * on `Origin`, because `User-Agent` is a forbidden header name and a browser
 * cannot present an allowlisted one. `authorize.ts` explains what that does and
 * does not buy.
 *
 * Both leave as the *same* upstream user-agent, because the MapTiler key's own
 * allowlist is a single exact value and the point of this layer is that the key
 * never appears in a client at all.
 */
export interface Env {
  /** MapTiler API key. A secret: `wrangler secret put MAPTILER_KEY`. */
  MAPTILER_KEY: string;
  /** Exact `User-Agent` values allowed to spend the key, comma separated. */
  ALLOWED_CLIENTS: string;
  /** Exact `Origin` values browsers may spend the key with, comma separated. */
  ALLOWED_ORIGINS?: string;
  /** Requests per native client per UTC day. */
  DAILY_QUOTA: string;
  /**
   * Requests per *origin* per UTC day, defaulting to `DAILY_QUOTA`.
   *
   * Separate from the native figure because it has to be: every browser user of
   * a deployment shares one bucket — there is no stable per-visitor identity a
   * browser can be asked for — and a map view is a few hundred requests, so the
   * native allowance would be gone in minutes.
   */
  WEB_DAILY_QUOTA?: string;
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
    const originHeader = request.headers.get('origin');

    // Echoed back on every response below, including refusals. A browser cannot
    // read an error it was not given permission to read, so without this a quota
    // refusal reaches the user as an opaque CORS failure instead of the
    // explanation. Computed before authorization precisely so the *refusal* path
    // can carry it too. Never `*`: that would make the proxy readable by any
    // page on the internet, which is the opposite of the allowlist.
    const corsOrigin = identifyOrigin(originHeader, parseClients(env.ALLOWED_ORIGINS));

    // Unauthenticated on purpose: it reveals nothing about the key, and a deploy
    // that 404s on its own health check is worse than one that leaks a boolean.
    if (url.pathname === '/__health') return withCors(json({ ok: true }), corsOrigin);

    /**
     * Preflight. MapLibre GL JS sends no custom headers, so tiles and styles are
     * simple requests and never arrive here — but a preflight that is answered
     * 405 makes the browser report a CORS error for *every* request that follows
     * it, turning one unsupported call into a blank map. Answered cheaply and
     * without touching upstream or the quota, because a browser never charges a
     * preflight against its own allowance.
     */
    if (request.method === 'OPTIONS') {
      return withCors(new Response(null, { status: 204 }), corsOrigin, {
        'access-control-allow-methods': 'GET, HEAD, OPTIONS',
        'access-control-allow-headers': 'content-type',
        'access-control-max-age': '86400',
      });
    }

    // MapLibre issues HEADs while probing a source. Forwarding them is cheaper
    // than refusing them, which would surface as a failed style load.
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return withCors(json({ error: 'method_not_allowed' }, 405), corsOrigin);
    }

    // An allowlist, so an unknown or future endpoint cannot be proxied by
    // accident. See §ALLOWED_PREFIXES.
    if (!isAllowedPath(url.pathname)) return withCors(json({ error: 'not_proxied' }, 404), corsOrigin);

    const today = todayUTC();
    const nativeLimit = Number(env.DAILY_QUOTA);
    const webLimit = Number(env.WEB_DAILY_QUOTA ?? env.DAILY_QUOTA);

    // Authorize on the identity alone first, so an unknown client costs one
    // Durable Object round trip and no upstream traffic.
    const identity = authorize(
      request.headers.get('user-agent'),
      originHeader,
      { userAgents: parseClients(env.ALLOWED_CLIENTS), origins: parseClients(env.ALLOWED_ORIGINS) },
      { day: today, count: 0 },
      nativeLimit,
      today
    );
    if (!identity.allowed) {
      return withCors(json({ error: identity.reason }, identity.status), corsOrigin);
    }

    const limit = limitFor(identity.kind, nativeLimit, webLimit);
    // Namespaced by kind so a native token and an origin can never collide in
    // the same Durable Object, and so one client class cannot spend the other's
    // allowance even if their identifiers happened to match.
    const quota = env.QUOTA.get(env.QUOTA.idFromName(`${identity.kind}:${identity.token}`));
    const spent = await quota.fetch(`https://quota/check?day=${today}&limit=${limit}`);
    if (spent.status !== 200) {
      const state = (await spent.json()) as { day: string; count: number };
      return withCors(
        json({ error: 'quota_exceeded', day: state.day, count: state.count, limit }, 429),
        corsOrigin
      );
    }

    const upstream = new Request(
      upstreamURL(env.UPSTREAM ?? 'https://api.maptiler.com', url.pathname, url.search, env.MAPTILER_KEY),
      {
        method: request.method,
        headers: upstreamHeaders(request.headers, upstreamIdentity(env, identity.kind)),
      }
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

    return withCors(
      isTileDocument(url.pathname)
        ? await rewritten(safe, request, env.UPSTREAM ?? 'https://api.maptiler.com', url.origin)
        : safe,
      corsOrigin
    );
  },
};

/**
 * Serve a style or TileJSON with the key taken out of it.
 *
 * `sanitizeUpstreamResponse` cannot do this job: the key in a style is in the
 * body, as part of a URL the renderer is going to follow. Stripping it is what
 * turns "the key ships in the app" into "the key does not ship in the app",
 * which is the whole point of this Worker.
 */
async function rewritten(
  response: Response,
  request: Request,
  upstream: string,
  proxyOrigin: string
): Promise<Response> {
  // A HEAD has no body, and an error body is already a fixed `upstream_rejected`
  // with nothing to rewrite.
  if (request.method === 'HEAD' || !response.ok) return response;

  const body = await response.text();
  let document: unknown;
  try {
    document = JSON.parse(body);
  } catch {
    // If MapTiler ever sends something unparseable, pass it through untouched.
    // Failing to understand the document is our bug; silently replacing it with
    // `{}` would hand the client a map with no sources and no error, which is
    // far harder to diagnose than a style that failed to load.
    return new Response(body, { status: response.status, headers: response.headers });
  }

  return new Response(JSON.stringify(rewriteTileDocument(document, upstream, proxyOrigin)), {
    status: response.status,
    headers: response.headers,
  });
}

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

/**
 * Add CORS headers for a verified origin.
 *
 * A no-op when the caller presented no allowlisted origin, which is every native
 * request: `NSURLSession` sends no `Origin` and is not subject to CORS at all.
 *
 * `Vary: Origin` is not optional. Cloudflare's cache is a shared cache in front
 * of this Worker, and without `Vary` a response built for one allowlisted origin
 * can be handed to another — which would mean either a cross-origin data leak or
 * a page mysteriously failing, depending on which order the cache filled in.
 */
function withCors(response: Response, origin: string | null, extra?: Record<string, string>): Response {
  const headers = new Headers(response.headers);
  if (origin) {
    headers.set('access-control-allow-origin', origin);
    headers.set('access-control-expose-headers', 'content-type');
  }
  headers.set('vary', 'Origin');
  for (const [name, value] of Object.entries(extra ?? {})) headers.set(name, value);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

/** The day's allowance for a caller. */
function limitFor(kind: ClientKind, nativeLimit: number, webLimit: number): number {
  return kind === 'web' ? webLimit : nativeLimit;
}

/**
 * The `User-Agent` this request leaves with.
 *
 * Both caller kinds present the same value, because the MapTiler key's allowlist
 * is a single exact string and this layer exists so that no client ever sees the
 * key. Giving the browser its own upstream identity would mean adding a second
 * entry to that allowlist and, with it, a second thing to revoke — for traffic
 * that is already attributable to a named origin bucket in the quota below.
 */
function upstreamIdentity(env: Env, _kind: ClientKind): string {
  const clients = parseClients(env.ALLOWED_CLIENTS);
  if (clients.length === 0) return '';
  return clients[0]!;
}

/** Forwarded request headers: the identity, and nothing that could carry a key. */
function upstreamHeaders(incoming: Headers, token: string): Headers {
  const headers = new Headers();
  // The allowlisted token, byte for byte. Rewriting this breaks the MapTiler key
  // allowlist, so the value this layer presents upstream is the one it was built
  // around — for both caller kinds. See §upstreamIdentity.
  headers.set('user-agent', token);
  const accept = incoming.get('accept');
  if (accept) headers.set('accept', accept);
  // Forwarded so MapTiler's own referrer restriction still applies to browser
  // traffic instead of being bypassed by the hop through here. A native client
  // sends no Origin, so this is absent for it, exactly as it is today.
  const origin = incoming.get('origin');
  if (origin) headers.set('origin', origin);
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