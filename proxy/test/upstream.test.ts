import { describe, expect, it } from 'vitest';
import {
  ALLOWED_PREFIXES,
  isAllowedPath,
  isTileDocument,
  rewriteTileDocument,
  sanitizeUpstreamResponse,
  upstreamURL,
} from '../src/upstream';

const UPSTREAM = 'https://api.maptiler.com';
const KEY = 'aBcDe123_secret_key_value';

describe('isAllowedPath', () => {
  it('allows the endpoints the app actually uses', () => {
    expect(isAllowedPath('/maps/outdoor-v2/style.json')).toBe(true);
    expect(isAllowedPath('/tiles/terrain-rgb-v2/1/2/3.png')).toBe(true);
    expect(isAllowedPath('/geocoding/maroon.json')).toBe(true);
    // Every style names this in its `glyphs` field, so without it the map loads
    // and silently loses its labels.
    expect(isAllowedPath('/fonts/Open%20Sans%20Regular/0-255.pbf')).toBe(true);
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
describe('isTileDocument', () => {
  it('picks out the two document shapes, and nothing else', () => {
    expect(isTileDocument('/maps/outdoor-v2/style.json')).toBe(true);
    expect(isTileDocument('/tiles/terrain-rgb-v2/tiles.json')).toBe(true);
  });

  it('leaves tile bodies and geocoding alone', () => {
    // A tile is binary; rewriting would corrupt it. Geocoding results name
    // nothing MapTiler-hosted, so parsing 200 KB of results to change none of
    // them is pure cost on the hot path for search.
    expect(isTileDocument('/tiles/terrain-rgb-v2/1/2/3.png')).toBe(false);
    expect(isTileDocument('/tiles/outdoor/1/2/3.pbf')).toBe(false);
    expect(isTileDocument('/fonts/Open%20Sans%20Regular/0-255.pbf')).toBe(false);
    expect(isTileDocument('/geocoding/maroon.json')).toBe(false);
  });
});

describe('rewriteTileDocument', () => {
  const PROXY = 'https://proxy.example';

  /** The real shape of the leak: five URLs, key in every one. */
  function styleWithKey(): unknown {
    return {
      version: 8,
      glyphs: `${UPSTREAM}/fonts/{fontstack}/{range}.pbf?key=${KEY}`,
      sources: {
        outdoor: { type: 'vector', url: `${UPSTREAM}/tiles/outdoor/tiles.json?key=${KEY}` },
        'terrain-rgb': { type: 'raster-dem', url: `${UPSTREAM}/tiles/terrain-rgb-v2/tiles.json?key=${KEY}` },
      },
      layers: [{ id: 'water', source: 'outdoor' }],
    };
  }

  it('takes the key out of every MapTiler URL and points them back here', () => {
    const rewritten = rewriteTileDocument(styleWithKey(), UPSTREAM, PROXY) as {
      glyphs: string;
      sources: Record<string, { url: string }>;
    };
    expect(rewritten.sources.outdoor!.url).toBe(`${PROXY}/tiles/outdoor/tiles.json`);
    expect(rewritten.sources['terrain-rgb']!.url).toBe(`${PROXY}/tiles/terrain-rgb-v2/tiles.json`);
    // The one that is easy to forget, and the only one that is a string at the
    // top level rather than inside `sources`.
    expect(rewritten.glyphs).toBe(`${PROXY}/fonts/{fontstack}/{range}.pbf`);
    expect(JSON.stringify(rewritten)).not.toContain(KEY);
  });

  /** TileJSON carries its tile addresses in `tiles[]`, not in `sources`. */
  it('rewrites the tiles array of a TileJSON', () => {
    const tilejson = {
      tiles: [`${UPSTREAM}/tiles/terrain-rgb-v2/{z}/{x}/{y}.png?key=${KEY}`],
      minzoom: 0,
      maxzoom: 14,
    };
    const rewritten = rewriteTileDocument(tilejson, UPSTREAM, PROXY) as { tiles: string[] };
    expect(rewritten.tiles).toEqual([`${PROXY}/tiles/terrain-rgb-v2/{z}/{x}/{y}.png`]);
  });

  /** `limit` and `proximity` are load-bearing for geocoding-adjacent documents. */
  it('keeps every query parameter except the key', () => {
    const doc = { sources: { s: { url: `${UPSTREAM}/tiles/x/tiles.json?key=${KEY}&tiles=42&format=pbf` } } };
    const rewritten = rewriteTileDocument(doc, UPSTREAM, PROXY) as { sources: Record<string, { url: string }> };
    const url = new URL(rewritten.sources.s!.url);
    expect(url.searchParams.get('key')).toBeNull();
    expect(url.searchParams.get('tiles')).toBe('42');
    expect(url.searchParams.get('format')).toBe('pbf');
  });

  /**
   * A style may legitimately point at somebody else's tileset. Rewriting that to
   * here would not proxy it — `isAllowedPath` refuses it — it would just break
   * it, while looking handled. Origins are compared, not prefixes, or a lookalike
   * host would be rewritten too.
   */
  it('leaves URLs that are not the upstream exactly as they are', () => {
    const doc = {
      sources: {
        thirdparty: { url: 'https://tiles.openfreemap.org/planet.json' },
        lookalike: { url: 'https://api.maptiler.com.evil.test/tiles/x/tiles.json?key=abc' },
      },
    };
    const rewritten = rewriteTileDocument(doc, UPSTREAM, PROXY) as { sources: Record<string, { url: string }> };
    expect(rewritten.sources.thirdparty!.url).toBe('https://tiles.openfreemap.org/planet.json');
    expect(rewritten.sources.lookalike!.url).toBe('https://api.maptiler.com.evil.test/tiles/x/tiles.json?key=abc');
  });

  /**
   * Only rewrite what the proxy would actually serve.
   *
   * A TileJSON carries a `logo` at `/resources/logo.svg`, which `isAllowedPath`
   * refuses. Rewriting that would swap a working image for a guaranteed 404
   * while looking handled — the failure mode of "point everything at me" is not
   * an error, it is silence.
   */
  it('does not point a URL at a path this proxy would refuse', () => {
    const doc = {
      logo: `${UPSTREAM}/resources/logo.svg?key=${KEY}`,
      sources: { outdoor: { url: `${UPSTREAM}/tiles/outdoor/tiles.json?key=${KEY}` } },
    };
    const rewritten = rewriteTileDocument(doc, UPSTREAM, PROXY) as {
      logo: string;
      sources: Record<string, { url: string }>;
    };
    expect(rewritten.logo).toBe(`${UPSTREAM}/resources/logo.svg?key=${KEY}`);
    // The one that is proxied still is.
    expect(rewritten.sources.outdoor!.url).toBe(`${PROXY}/tiles/outdoor/tiles.json`);
  });

  it('tolerates a trailing slash on its own origin', () => {
    const rewritten = rewriteTileDocument({ glyphs: `${UPSTREAM}/fonts/a/0-255.pbf?key=${KEY}` }, UPSTREAM, `${PROXY}/`) as {
      glyphs: string;
    };
    expect(rewritten.glyphs).toBe(`${PROXY}/fonts/a/0-255.pbf`);
  });

  /** Document structure is not this function's to change. */
  it('preserves everything that is not a URL', () => {
    const doc = styleWithKey();
    const rewritten = rewriteTileDocument(doc, UPSTREAM, PROXY) as Record<string, unknown>;
    expect(rewritten.version).toBe(8);
    expect(rewritten.layers).toEqual([{ id: 'water', source: 'outdoor' }]);
  });

  it('leaves a non-URL string alone rather than throwing', () => {
    const rewritten = rewriteTileDocument({ id: 'not a url at all', n: 1, b: true, z: null }, UPSTREAM, PROXY) as {
      id: string;
    };
    expect(rewritten.id).toBe('not a url at all');
  });
});
