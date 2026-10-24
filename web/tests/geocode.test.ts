import { afterEach, describe, expect, it, vi } from 'vitest';
import { geocode, geocodeWithFallback, geocodeUrl, GEOCODE_TYPES, normalizeFeature, placeTypeLabel, rankSearchResults, relaxedQuery, STRONG_MATCH_RELEVANCE, type GeocodeResult } from '../src/geocode';

const townFeature = {
  id: 'municipality.46425',
  text: 'Chamonix-Mont-Blanc',
  place_name: 'Chamonix-Mont-Blanc, France',
  place_type: ['municipality'],
  properties: { place_designation: 'town' },
  geometry: { type: 'Point', coordinates: [6.8694, 45.9237] },
  bbox: [6.752, 45.87, 7.052, 46.09],
};

const peakFeature = {
  id: 'poi.123',
  text: 'Little Bear Peak',
  place_name: 'Little Bear Peak, Alamosa, United States',
  place_type: ['poi'],
  relevance: 0.96,
  properties: { categories: ['peak'], feature_tags: { natural: 'peak', ele: '4280' } },
  geometry: { type: 'Point', coordinates: [-105.497, 37.567] },
  context: [
    { id: 'county.23768', text: 'Alamosa' },
    { id: 'region.2138', text: 'Colorado' },
    { id: 'country.213', text: 'United States' },
  ],
};

const peakWithoutCounty = {
  ...peakFeature,
  context: [{ id: 'region.2138', text: 'Colorado' }, { id: 'country.213', text: 'United States' }],
};

const peakWithoutElevation = {
  ...peakFeature,
  properties: { categories: ['peak'] },
};

const trailFeature = {
  id: 'address.24163432',
  text: 'Eagle Valley Trail',
  place_name: 'Eagle Valley Trail, Eagle, Colorado 81631, United States',
  place_type: ['address'],
  properties: { kind: 'street' },
  geometry: { type: 'Point', coordinates: [-106.5471, 39.6365] },
  bbox: [-106.8, 39.5, -106.3, 39.7],
  context: [
    { id: 'county.144', text: 'Eagle' },
    { id: 'region.2138', text: 'Colorado' },
    { id: 'country.213', text: 'United States' },
  ],
};

const trailheadFeature = {
  id: 'poi.4242',
  text: 'Kilpacker Trailhead',
  place_name: 'Kilpacker Trailhead, Dolores, Colorado, United States',
  place_type: ['poi'],
  properties: { categories: ['parking'], feature_tags: { amenity: 'parking' } },
  geometry: { type: 'Point', coordinates: [-108.06, 37.79] },
};

const backcountryRoadFeature = {
  id: 'address.555',
  text: 'Lead King Basin Road',
  place_name: 'Lead King Basin Road, Gunnison, Colorado, United States',
  place_type: ['address'],
  properties: { kind: 'street' },
  geometry: { type: 'Point', coordinates: [-107.13, 39.08] },
};

describe('geocodeUrl', () => {
  it('encodes the query and pins the type filter and limit', () => {
    const url = geocodeUrl('Mount Rainier');
    expect(url.startsWith('https://proxy.test/geocoding/Mount%20Rainier.json')).toBe(true);
    expect(url).toContain(`types=${GEOCODE_TYPES}`);
    expect(url).toContain('address');
    expect(url).toContain('limit=10');
    expect(url).not.toContain('proximity=');
  });

  /**
   * Scoring the completed query is what makes "Rock Creek National Park" find
   * Rock Creek Park: the autocomplete default assumes the query is still being
   * typed, and loose word matches then beat an exact full-name feature.
   */
  it('scores the whole query rather than as a keystroke prefix', () => {
    const url = geocodeUrl('Rock Creek National Park');
    expect(url).toContain('autocomplete=false');
  });

  /**
   * The key moved into the proxy's secrets. A `key=` in this URL would put it
   * back in the shipped bundle and in every log that records a request line.
   */
  it('never puts a key in the query', () => {
    const url = geocodeUrl('Mount Rainier');
    expect(url).not.toContain('key=');
    expect(url).not.toContain('maptiler');
  });

  it('adds the proximity parameter when a map position is given', () => {
    const url = geocodeUrl('Mount Rainier', { proximity: { lon: -121.7576, lat: 46.8523 } });
    expect(url).toContain('proximity=-121.7576,46.8523');
  });
});

describe('normalizeFeature', () => {
  it('maps a settlement with a bounding box and a compact region', () => {
    const result = normalizeFeature(townFeature);
    expect(result).toEqual({
      id: 'municipality.46425',
      name: 'Chamonix-Mont-Blanc',
      region: 'France',
      typeLabel: 'Town',
      center: { lon: 6.8694, lat: 45.9237 },
      bbox: [6.752, 45.87, 7.052, 46.09],
    });
  });

  it('rebuilds the region from context for peaks (county + state + country)', () => {
    const result = normalizeFeature(peakFeature);
    expect(result?.region).toBe('Alamosa, Colorado, USA');
    expect(result?.typeLabel).toBe('Peak');
    expect(result?.elevation).toBe(4280);
    expect(result?.relevance).toBe(0.96);
    expect(result?.bbox).toBeUndefined();
  });

  /** MapTiler omits the score on some responses; ranking must hold the line without it. */
  it('keeps a result usable when the API sends no relevance score', () => {
    expect(normalizeFeature({ ...peakFeature, relevance: undefined })?.relevance).toBeUndefined();
    expect(normalizeFeature({ ...peakFeature, relevance: 0 })?.relevance).toBe(0);
  });

  it('falls back to state + country when a peak has no county context', () => {
    expect(normalizeFeature(peakWithoutCounty)?.region).toBe('Colorado, USA');
  });

  it('omits elevation when the peak has no elevation tag', () => {
    expect(normalizeFeature(peakWithoutElevation)?.elevation).toBeUndefined();
  });

  it('labels named trails indexed as addresses', () => {
    const result = normalizeFeature(trailFeature);
    expect(result?.typeLabel).toBe('Trail');
    expect(result?.name).toBe('Eagle Valley Trail');
    expect(result?.region).toBe('Eagle, Colorado, USA');
    expect(result?.bbox).toEqual([-106.8, 39.5, -106.3, 39.7]);
  });

  it('labels trailhead POIs', () => {
    const result = normalizeFeature(trailheadFeature);
    expect(result?.typeLabel).toBe('Trailhead');
    expect(result?.name).toBe('Kilpacker Trailhead');
  });

  it('keeps backcountry roads but labels them as streets', () => {
    const result = normalizeFeature(backcountryRoadFeature);
    expect(result?.typeLabel).toBe('Street');
    expect(result?.name).toBe('Lead King Basin Road');
  });

  it('skips non-Point geometries', () => {
    expect(normalizeFeature({ geometry: { type: 'LineString', coordinates: [] } })).toBeNull();
  });

  it('skips Point geometries without valid coordinates', () => {
    expect(normalizeFeature({ geometry: { type: 'Point', coordinates: [] } })).toBeNull();
    expect(normalizeFeature({ geometry: { type: 'Point', coordinates: ['x', 1] } })).toBeNull();
  });
});

/** A hand-built result, the way the list sees it. */
const result = (over: Partial<GeocodeResult> & Pick<GeocodeResult, 'name' | 'center'>): GeocodeResult => ({
  id: `id-${over.name}-${over.center.lon},${over.center.lat}`,
  region: 'somewhere',
  typeLabel: 'Place',
  ...over,
});

describe('rankSearchResults', () => {
  it('is stable in API order when no center is given', () => {
    const a = result({ name: 'Rock Creek Park', center: { lon: -77.046, lat: 38.963 } });
    const b = result({ name: 'Rock Creek Cemetery', center: { lon: -77.012, lat: 38.948 } });
    expect(rankSearchResults([a, b])).toEqual([a, b]);
  });

  /**
   * The issue's own example, at the scale it bites: "Rock Creek Park" exists as
   * a landform in Washington and as a place in Maryland, and MapTiler scores
   * both 0.7. Which one the user means is answered by what is on screen — the
   * map center — not by the order the index happens to hold them in.
   */
  it('breaks an equal-relevance tie by distance from the map center', () => {
    const nearby = result({ name: 'Rock Creek Park', relevance: 0.7, center: { lon: -77.046, lat: 38.963 } });
    const far = result({ name: 'Rock Creek Park', relevance: 0.7, center: { lon: -76.491, lat: 39.146 } });

    const ranked = rankSearchResults([far, nearby], { lon: -77.0369, lat: 38.9097 });
    expect(ranked[0]).toBe(nearby);
  });

  it('still puts a clearly better match above a merely closer one', () => {
    const exactButFar = result({ name: 'Boneyard Trail', relevance: 1, center: { lon: 6.8694, lat: 45.9237 } });
    const nearButFuzzy = result({ name: 'Boneyard Creek', relevance: 0.5, center: { lon: -77.1, lat: 38.9 } });

    const ranked = rankSearchResults([nearButFuzzy, exactButFar], { lon: -77.0369, lat: 38.9097 });
    expect(ranked[0]).toBe(exactButFar);
  });

  it('ranks a result the API scored nothing below scored ones', () => {
    const unscored = result({ name: 'Bradley Park', center: { lon: -77.1, lat: 38.92 } });
    const scored = result({ name: 'Rock Creek Park', relevance: 0.4, center: { lon: -77.046, lat: 38.963 } });

    const ranked = rankSearchResults([unscored, scored], { lon: -77.046, lat: 38.963 });
    expect(ranked[0]).toBe(scored);
  });

  /**
   * Whole-query scoring rings the limit with exact matches — nine near-identical
   * "Grand Canyon" points — and rows the user cannot tell apart are noise.
   * Collapsing keeps the ranked instance: for a sprawling feature, the
   * occurrence closest to what is on screen.
   */
  it('collapses namesakes the list cannot tell apart, keeping the nearest', () => {
    const west = result({ name: 'Grand Canyon', typeLabel: 'Point of interest', relevance: 0.96, center: { lon: -112.1, lat: 36.06 } });
    const east = result({ name: 'Grand Canyon', typeLabel: 'Point of interest', relevance: 0.96, center: { lon: -111.8, lat: 36.1 } });

    const ranked = rankSearchResults([east, west], { lon: -112.11, lat: 36.05 });
    expect(ranked).toHaveLength(1);
    expect(ranked[0]).toBe(west);
  });

  it('keeps same-named results with different badges, which users can tell apart', () => {
    const mountain = result({ name: 'Mount Rainier', typeLabel: 'Peak', relevance: 0.96, center: { lon: -121.7576, lat: 46.8523 } });
    const school = result({ name: 'Mount Rainier', typeLabel: 'Point of interest', relevance: 0.96, center: { lon: -122.2708, lat: 47.2362 } });

    const ranked = rankSearchResults([school, mountain], { lon: -121.76, lat: 46.85 });
    expect(ranked).toEqual([mountain, school]);
  });

  it('does not mutate the list it is given', () => {
    const a = result({ name: 'A', relevance: 0.2, center: { lon: 0, lat: 0 } });
    const b = result({ name: 'B', relevance: 1, center: { lon: 10, lat: 10 } });
    const input = [a, b];
    rankSearchResults(input, { lon: 9, lat: 9 });
    expect(input).toEqual([a, b]);
  });
});

describe('placeTypeLabel', () => {
  it('prefers the OSM place designation for populated places', () => {
    expect(placeTypeLabel('place', 'village')).toBe('Village');
    expect(placeTypeLabel('place', 'town')).toBe('Town');
  });
  it('falls back to the place type', () => {
    expect(placeTypeLabel('municipality')).toBe('Municipality');
    expect(placeTypeLabel('poi')).toBe('Point of interest');
    expect(placeTypeLabel('major_landform')).toBe('Mountain range / landform');
  });
  it('defaults to Place for unknown kinds', () => {
    expect(placeTypeLabel(undefined)).toBe('Place');
    expect(placeTypeLabel('unknown_kind')).toBe('Place');
  });
});

describe('geocode', () => {
  afterEach(() => vi.unstubAllGlobals());

  const mockFetch = (features: unknown[], ok = true) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok, json: () => Promise.resolve({ features }) }));
  };

  it('returns normalized results and skips unusable features', async () => {
    mockFetch([peakFeature, { geometry: { type: 'LineString' } }]);
    const results = await geocode('little bear peak');
    expect(results).toHaveLength(1);
    expect(results[0]).toMatchObject<GeocodeResult>({
      name: 'Little Bear Peak',
      typeLabel: 'Peak',
      region: 'Alamosa, Colorado, USA',
      elevation: 4280,
      center: { lon: -105.497, lat: 37.567 },
    });
  });

  it('passes the map position as proximity', async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: () => Promise.resolve({ features: [peakFeature] }) });
    vi.stubGlobal('fetch', fetchMock);
    await geocode('little bear peak', { proximity: { lon: -105.56, lat: 37.57 } });
    const url = fetchMock.mock.calls[0][0] as string;
    expect(url).toContain('proximity=-105.56,37.57');
  });

  it('returns [] for a non-OK response', async () => {
    mockFetch([], false);
    expect(await geocode('chamonix')).toEqual([]);
  });

  it('returns [] when fetch rejects', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('network down')));
    expect(await geocode('chamonix')).toEqual([]);
  });

  it('returns [] for a blank query without fetching', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    expect(await geocode('   ')).toEqual([]);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('relaxedQuery', () => {
  /** The reported case: the official name carries a word the index does not. */
  it('drops the first decorative word', () => {
    expect(relaxedQuery('Rock Creek National Park')).toBe('Rock Creek Park');
  });

  it('does not care where the decoration sits', () => {
    expect(relaxedQuery('National Mining Memorial Rock')).toBe('Mining Memorial Rock');
  });

  it('is case-insensitive about the decoration itself', () => {
    expect(relaxedQuery('Rock Creek NATIONAL Park')).toBe('Rock Creek Park');
  });

  it('returns null when there is no decoration to relax away', () => {
    expect(relaxedQuery('Rock Creek')).toBeNull();
    expect(relaxedQuery('Half Dome')).toBeNull();
  });

  it('returns null when relaxation would ask a question with no words in it', () => {
    expect(relaxedQuery('National Park')).toBeNull();
    expect(relaxedQuery('park')).toBeNull();
  });

  it('leaves non-decorative words alone even when they look close', () => {
    expect(relaxedQuery('Sparkle Parklight')).toBeNull();
  });
});

describe('geocodeWithFallback', () => {
  afterEach(() => vi.unstubAllGlobals());

  const feature = (name: string, relevance: number) => ({
    text: name,
    place_type: ['poi'],
    relevance,
    geometry: { type: 'Point', coordinates: [-77.046, 38.963] },
  });

  const DC = { proximity: { lon: -77.0369, lat: 38.9097 } };

  /** A `fetch` that answers with different features per query in the URL. */
  function fetchPerQuery(byQuery: Record<string, unknown[]>) {
    return vi.fn(async (url: string | URL | Request) => {
      const requested = decodeURIComponent(String(url).replace(/^.*\/geocoding\//, '').replace(/\.json.*$/, ''));
      const features = byQuery[requested] ?? [];
      return { ok: true, json: () => Promise.resolve({ features }) } as Response;
    });
  }

  it('asks once when the API already found the name', async () => {
    const impl = fetchPerQuery({ 'Half Dome': [feature('Half Dome', 0.96)] });
    vi.stubGlobal('fetch', impl);

    const results = await geocodeWithFallback('Half Dome', DC);

    expect(results[0]?.name).toBe('Half Dome');
    expect(impl).toHaveBeenCalledTimes(1);
  });

  /**
   * The reported scenario, exactly as the API answered it on the day: the
   * decorated query scores 0.69 and never contains the park; dropping the
   * stray "National" scores 1.0 and finds it first.
   */
  it('retries without the decoration when the whole query is matched loosely', async () => {
    const impl = fetchPerQuery({
      // Whole query as asked: the best it has is a zoo and a same-named Colorado
      // creek. The park is not in this answer at all.
      'Rock Creek National Park': [feature('National Zoological Park', 0.69), feature('Rock Creek', 0.69)],
      'Rock Creek Park': [feature('Rock Creek Park', 1)],
    });
    vi.stubGlobal('fetch', impl);

    const results = await geocodeWithFallback('Rock Creek National Park', DC);

    expect(results[0]?.name).toBe('Rock Creek Park');
    expect(impl).toHaveBeenCalledTimes(2);
  });

  it('keeps the original when the relaxed query matches more loosely', async () => {
    const impl = fetchPerQuery({
      'Rock Creek National Park': [feature('National Zoological Park', 0.69)],
      // A weaker answer: it isn't enough to just relax, the relaxer only swaps
      // for a match the API believes more strongly.
      'Rock Creek Park': [feature('Rose Park', 0.5)],
    });
    vi.stubGlobal('fetch', impl);

    const results = await geocodeWithFallback('Rock Creek National Park', DC);

    expect(results[0]?.name).toBe('National Zoological Park');
  });

  it('does not retry when the query carries no decoration to drop', async () => {
    const impl = fetchPerQuery({ 'Rock Creek': [feature('Rock Creek', 0.7)] });
    vi.stubGlobal('fetch', impl);

    await geocodeWithFallback('Rock Creek', DC);

    expect(impl).toHaveBeenCalledTimes(1);
  });

  it('relaxes again while the answer stays loose, at most twice', async () => {
    const impl = fetchPerQuery({
      'Fancy State Forest National Memorial Area': [feature('Noise', 0.3)],
      'Fancy Forest National Memorial Area': [feature('Noise', 0.4)],
      'Fancy National Memorial Area': [feature('Noise', 0.5)],
    });
    vi.stubGlobal('fetch', impl);

    await geocodeWithFallback('Fancy State Forest National Memorial Area', DC);

    // The as-asked round plus the two relaxed rounds; the cap is what keeps a
    // decoration-dense miss from turning into an unbounded row of requests.
    expect(impl).toHaveBeenCalledTimes(3);
  });

  it('returns [] for a blank query without fetching', async () => {
    const impl = vi.fn();
    vi.stubGlobal('fetch', impl);
    expect(await geocodeWithFallback('   ', DC)).toEqual([]);
    expect(impl).not.toHaveBeenCalled();
  });

  /** The floor sits between loose (0.69-type) and exact (0.96-type) answers. */
  it('declares strong matches at the seam the API actually exhibits', () => {
    expect(STRONG_MATCH_RELEVANCE).toBeGreaterThanOrEqual(0.85);
    expect(STRONG_MATCH_RELEVANCE).toBeLessThanOrEqual(0.93);
  });
});