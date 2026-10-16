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