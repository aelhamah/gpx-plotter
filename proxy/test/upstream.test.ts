import { describe, expect, it } from 'vitest';
import { ALLOWED_PREFIXES, isAllowedPath, sanitizeUpstreamResponse, upstreamURL } from '../src/upstream';

const UPSTREAM = 'https://api.maptiler.com';
const KEY = 'aBcDe123_secret_key_value';

describe('isAllowedPath', () => {
  it('allows the endpoints the app actually uses', () => {
    expect(isAllowedPath('/maps/outdoor-v2/style.json')).toBe(true);
    expect(isAllowedPath('/tiles/terrain-rgb-v2/1/2/3.png')).toBe(true);
    expect(isAllowedPath('/geocoding/maroon.json')).toBe(true);
  });

  /**
   * An allowlist rather than a denylist: an endpoint nobody has heard of yet must
   * fail closed, because the cost of allowing it is somebody else's bill.
   */
  it('refuses anything not on the list', () => {
    expect(isAllowedPath('/')).toBe(false);
    expect(isAllowedPath('/admin')).toBe(false);
    expect(isAllowedPath('/tiles')).toBe(false); // prefix is '/tiles/', with the slash
    expect(isAllowedPath('/maptiler-admin/keys')).toBe(false);
  });

  it('is not fooled by a prefix that only looks similar', () => {
    expect(isAllowedPath('/mapsx/../admin')).toBe(false);
    expect(isAllowedPath('/geocoding')).toBe(false);
  });

  it('cannot be satisfied by a traversal that re-enters an allowed prefix', () => {
    // `/admin/../tiles/x` is a path that *ends* under an allowed prefix, and is
    // allowed on its merits -- but it is normalised before it is used, so the
    // upstream request is for `/tiles/x`, which is what gets fetched.
    const raw = '/admin/../tiles/terrain-rgb-v2/1/2/3.png';
    const normalized = new URL(raw, 'https://proxy.invalid').pathname;
    expect(normalized).toBe('/tiles/terrain-rgb-v2/1/2/3.png');
    expect(isAllowedPath(normalized)).toBe(true);
  });

  it('has an allowlist that is all prefixes, so nothing can default open', () => {
    expect(ALLOWED_PREFIXES.every((prefix) => prefix.startsWith('/') && prefix.endsWith('/'))).toBe(true);
  });
});

describe('upstreamURL', () => {
  it('keeps the path and query and adds the key', () => {
    const url = upstreamURL(UPSTREAM, '/maps/outdoor-v2/style.json', '', KEY);
    expect(url).toBe(`https://api.maptiler.com/maps/outdoor-v2/style.json?key=${KEY}`);
  });

  it('preserves an existing query, which the geocoder needs', () => {
    const url = upstreamURL(UPSTREAM, '/geocoding/x.json', '?limit=6&proximity=-106,39', KEY);
    const parsed = new URL(url);
    expect(parsed.pathname).toBe('/geocoding/x.json');
    expect(parsed.searchParams.get('limit')).toBe('6');
    expect(parsed.searchParams.get('proximity')).toBe('-106,39');
    expect(parsed.searchParams.get('key')).toBe(KEY);
  });

  /** A key with URL-special characters must arrive intact, not half-escaped. */
  it('encodes a key with awkward characters', () => {
    const awkward = 'a+b/c=d&e';
    const parsed = new URL(upstreamURL(UPSTREAM, '/maps/x/style.json', '', awkward));
    expect(parsed.searchParams.get('key')).toBe(awkward);
  });

  /**
   * The classic proxy escape. `//evil.example` is a network-path reference, so
   * naive concatenation sends the key to somebody else's host.
   */
  it('cannot be made to send the key to another host', () => {
    expect(() => upstreamURL(UPSTREAM, '//evil.example/maps/x.json', '', KEY)).not.toThrow();
    // Whatever it produces, it is either refused or stays on the upstream host.
    let produced: string | null = null;
    try {
      produced = upstreamURL(UPSTREAM, '//evil.example/maps/x.json', '', KEY);
    } catch {
      produced = null;
    }
    if (produced !== null) {
      expect(new URL(produced).host).toBe('api.maptiler.com');
    }
  });

  it('tolerates a trailing slash on the upstream', () => {
    expect(upstreamURL(`${UPSTREAM}/`, '/maps/x/style.json', '', KEY)).toBe(
      `https://api.maptiler.com/maps/x/style.json?key=${KEY}`
    );
  });
});

describe('sanitizeUpstreamResponse', () => {
  it('passes a successful body through', async () => {
    const response = sanitizeUpstreamResponse(
      new Response('PNG-ish bytes', { status: 200, headers: { 'content-type': 'image/png' } })
    );
    expect(response.status).toBe(200);
    expect(await response.text()).toBe('PNG-ish bytes');
    expect(response.headers.get('content-type')).toBe('image/png');
  });

  /**
   * The header is the enforceable half of "does not cache": a reviewer reading
   * only the response can see there is no store, without reading the body.
   */
  it('marks a successful response as no-store', () => {
    const response = sanitizeUpstreamResponse(new Response('x', { status: 200 }));
    expect(response.headers.get('cache-control')).toBe('no-store');
    expect(response.headers.get('x-proxy-cache')).toBe('disabled');
  });

  /**
   * MapTiler's error responses can echo the request URL, and that URL now carries
   * `?key=…`. Forwarding the body would turn any 4xx into a way to read the key.
   */
  it('never forwards an error body, because it can echo the key', async () => {
    const upstream = new Response(
      `Not found: https://api.maptiler.com/maps/nope/style.json?key=${KEY}`,
      { status: 404, headers: { 'content-type': 'text/html' } }
    );
    const response = sanitizeUpstreamResponse(upstream);
    expect(response.status).toBe(502);
    const body = await response.text();
    expect(body).not.toContain(KEY);
    expect(body).not.toContain('key=');
    expect(JSON.parse(body)).toEqual({ error: 'upstream_rejected', status: 404 });
  });

  it('turns every upstream failure into a 502 with no detail leaked', async () => {
    for (const status of [400, 401, 403, 429, 500, 503]) {
      const response = sanitizeUpstreamResponse(new Response('upstream said no', { status }));
      expect(response.status).toBe(502);
      expect(await response.text()).not.toContain('upstream said no');
    }
  });

  it('does not forward caching validators for a body it does not keep', () => {
    const upstream = new Response('x', { status: 200, headers: { etag: '"abc"', 'last-modified': 'today' } });
    const response = sanitizeUpstreamResponse(upstream);
    expect(response.headers.get('etag')).toBeNull();
    expect(response.headers.get('last-modified')).toBeNull();
  });
});