/**
 * Turning an incoming request into an upstream one.
 *
 * Two jobs, both of which are security boundaries rather than convenience:
 * deciding what may be proxied at all, and making sure the key cannot escape in a
 * URL, a header or an error page.
 */

/**
 * Path prefixes this proxy will forward.
 *
 * An allowlist, never a denylist. A denylist of MapTiler endpoints would need to
 * know every endpoint that exists and every future one, and the failure mode of
 * getting that wrong is proxying something expensive to anybody who finds it.
 */
export const ALLOWED_PREFIXES = [
  '/maps/',       // style.json
  '/tiles/',      // terrain-rgb, satellite-v2 rasters
  // Glyph ranges. Every MapTiler style names this in its `glyphs` field, so
  // leaving it out does not fail loudly — it fails as street and place labels
  // quietly disappearing from the map, which is the kind of bug that survives
  // QA because the map still looks like a map.
  '/fonts/',
  '/geocoding/',  // forward geocoding
] as const;

/** Whether a path may be forwarded upstream. */
export function isAllowedPath(pathname: string): boolean {
  return ALLOWED_PREFIXES.some((prefix) => pathname.startsWith(prefix));
}

/**
 * The upstream URL for a request.
 *
 * `pathname` and `search` are re-read from the parsed URL rather than taken from
 * the raw string, so `//evil.example/x` cannot be smuggled through as a
 * different host: anything that does not begin with an allowed prefix never gets
 * as far as concatenation.
 */
export function upstreamURL(upstream: string, pathname: string, search: string, apiKey: string): string {
  const base = upstream.endsWith('/') ? upstream.slice(0, -1) : upstream;
  // `URL` re-parses, which is the point: it normalises anything hostile and
  // refuses anything it cannot make sense of.
  const url = new URL(`${base}${pathname}${search}`);
  url.searchParams.set('key', apiKey);
  return url.toString();
}

/**
 * Strip anything from an upstream response that could carry the key back out.
 *
 * The important one is the body. MapTiler's error responses can echo the request
 * URL, and that URL now contains `?key=…` — so a proxied 404 is a working exfiltration
 * path for the key to whoever triggered it. On any non-2xx the body is therefore
 * discarded rather than sanitised: the app gets a machine-readable code and the
 * Worker keeps a log line, which is strictly more useful than MapTiler's HTML and
 * is the only version of it that is safe to hand back.
 */
export function sanitizeUpstreamResponse(response: Response): Response {
  if (response.ok) {
    const headers = new Headers();
    // `content-type` is kept because the client uses it to tell a tile from an
    // error. Everything else is dropped: `etag` and `last-modified` describe
    // state this layer deliberately does not have.
    const contentType = response.headers.get('content-type');
    if (contentType) headers.set('content-type', contentType);
    // Explicit, and the reason §Caching is written the way it is. The app has its
    // own on-disk cache; this layer holds nothing.
    headers.set('cache-control', 'no-store');
    headers.set('x-proxy-cache', 'disabled');
    return new Response(response.body, { status: response.status, headers });
  }

  return new Response(
    JSON.stringify({ error: 'upstream_rejected', status: response.status }),
    {
      status: 502,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    }
  );
}

/**
 * Paths whose body is a JSON document that *names other MapTiler URLs*.
 *
 * ## Why this exists
 *
 * Sanitising the response is not enough to keep the key out of the app. A style
 * is not a tile: it is a document describing where the tiles are, and MapTiler
 * writes the key into every one of those addresses.
 *
 *     style.sources.outdoor.url  = https://api.maptiler.com/tiles/outdoor/tiles.json?key=…
 *     style.glyphs               = https://api.maptiler.com/fonts/{fontstack}/{range}.pbf?key=…
 *
 * Proxying that verbatim hands the key straight to whoever asked, and the key is
 * in the response body rather than in a header where `sanitizeUpstreamResponse`
 * could reach it. Four of the five occurrences are TileJSON documents that the
 * renderer then fetches, so the leak is not even confined to the first response.
 *
 * So these two path shapes are parsed, rewritten to point back here, and
 * re-served. The key then never leaves the Worker — which is the entire reason
 * this Worker exists.
 */
export function isTileDocument(pathname: string): boolean {
  return pathname.endsWith('/style.json') || pathname.endsWith('/tiles.json');
}

/**
 * Rewrite every MapTiler URL in a tile document to point back at this Worker.
 *
 * Walks the whole document rather than knowing where the URLs live, because the
 * places they turn up are MapTiler's business, not this module's: `sources[*].url`
 * and `glyphs` in a style, `tiles[]` in a TileJSON, and whatever the next style
 * release decides to add.
 *
 * Only URLs whose *origin* is the upstream are touched. A style is allowed to
 * reference somebody else's tileset, and rewriting that to point here would not
 * proxy it — `isAllowedPath` would refuse it — it would just break it, while
 * looking like the proxy had handled it. Anything unparseable is passed through
 * untouched, for the same reason: a rewriting bug must not take the map down.
 */
export function rewriteTileDocument<T>(document: T, upstreamBase: string, proxyOrigin: string): T {
  return rewriteValue(document, new URL(upstreamBase).origin, proxyOrigin.replace(/\/+$/, '')) as T;
}

function rewriteValue(value: unknown, upstreamOrigin: string, proxyOrigin: string): unknown {
  if (typeof value === 'string') return rewriteURL(value, upstreamOrigin, proxyOrigin);
  if (Array.isArray(value)) return value.map((entry) => rewriteValue(entry, upstreamOrigin, proxyOrigin));
  if (value !== null && typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(value)) {
      out[key] = rewriteValue(entry, upstreamOrigin, proxyOrigin);
    }
    return out;
  }
  return value;
}

function rewriteURL(raw: string, upstreamOrigin: string, proxyOrigin: string): string {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return raw;
  }
  // Compared as origins, not as prefixes: `https://api.maptiler.com.evil.test/x`
  // starts with the upstream and is not the upstream.
  if (url.origin !== upstreamOrigin) return raw;

  // Only rewrite what this Worker would actually serve. A style's `logo` field
  // points at `/resources/logo.svg`, which `isAllowedPath` refuses — so
  // rewriting it would replace a working image with a guaranteed 404 and look
  // like the proxy had handled it. Anything left alone keeps pointing upstream,
  // where it at least has a chance of working without a key.
  if (!isAllowedPath(url.pathname)) return raw;

  // Deliberately *not* `url.pathname`. Re-serialising a `URL` percent-encodes the
  // `{z}/{x}/{y}` a tile template is made of, so the renderer would be handed
  // `%7Bz%7D` and every tile request would go out literally named that — a map
  // that loads a style and then requests nothing. The path is taken from the
  // original text, byte for byte.
  const rest = raw.startsWith(url.origin)
    ? raw.slice(url.origin.length)
    : `${url.pathname}${url.search}`;
  const queryAt = rest.indexOf('?');
  const path = queryAt === -1 ? rest : rest.slice(0, queryAt);

  // The proxy adds the key on the way back in, so carrying it here would only
  // hand out a secret that is about to be replaced by one this layer controls.
  const search = new URLSearchParams(queryAt === -1 ? '' : rest.slice(queryAt + 1));
  search.delete('key');
  const query = search.toString();
  return query ? `${proxyOrigin}${path}?${query}` : `${proxyOrigin}${path}`;
}