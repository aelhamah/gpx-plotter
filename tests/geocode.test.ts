import { afterEach, describe, expect, it, vi } from 'vitest';
import { geocode, geocodeUrl, GEOCODE_TYPES, normalizeFeature, placeTypeLabel, type GeocodeResult } from '../src/geocode';

const townFeature = {
  id: 'municipality.46425',
  text: 'Chamonix-Mont-Blanc',
  place_name: 'Chamonix-Mont-Blanc, Haute-Savoie, France',
  place_type: ['municipality'],
  place_designation: 'city',
  geometry: { type: 'Point', coordinates: [6.8694, 45.9237] },
  bbox: [6.752, 45.87, 7.052, 46.09],
};

const peakFeature = {
  id: 'poi.123',
  text: 'Mount Rainier',
  place_formatted: 'Mount Rainier, WA, United States of America',
  place_type: ['poi'],
  geometry: { type: 'Point', coordinates: [-121.7576, 46.8523] },
};

describe('geocodeUrl', () => {
  it('encodes the query and pins the key, type filter, and limit', () => {
    const url = geocodeUrl('Mount Rainier');
    expect(url.startsWith('https://api.maptiler.com/geocoding/Mount%20Rainier.json')).toBe(true);
    expect(url).toContain('key=');
    expect(url).toContain(`types=${GEOCODE_TYPES}`);
    expect(url).toContain('limit=6');
  });
});

describe('normalizeFeature', () => {
  it('maps a feature with a bounding box to a full result', () => {
    const result = normalizeFeature(townFeature);
    expect(result).toEqual({
      id: 'municipality.46425',
      name: 'Chamonix-Mont-Blanc',
      region: 'Haute-Savoie, France',
      typeLabel: 'City',
      center: { lon: 6.8694, lat: 45.9237 },
      bbox: [6.752, 45.87, 7.052, 46.09],
    });
  });

  it('leaves bbox undefined when the feature has none (e.g. a peak)', () => {
    const result = normalizeFeature(peakFeature);
    expect(result?.bbox).toBeUndefined();
    expect(result?.typeLabel).toBe('Point of interest');
    expect(result?.region).toBe('WA, United States of America');
  });

  it('skips non-Point geometries', () => {
    expect(normalizeFeature({ geometry: { type: 'LineString', coordinates: [] } })).toBeNull();
  });

  it('skips Point geometries without valid coordinates', () => {
    expect(normalizeFeature({ geometry: { type: 'Point', coordinates: [] } })).toBeNull();
    expect(normalizeFeature({ geometry: { type: 'Point', coordinates: ['x', 1] } })).toBeNull();
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
    mockFetch([townFeature, { geometry: { type: 'LineString' } }]);
    const results = await geocode('chamonix');
    expect(results).toHaveLength(1);
    expect(results[0]).toMatchObject<GeocodeResult>({
      name: 'Chamonix-Mont-Blanc',
      center: { lon: 6.8694, lat: 45.9237 },
      bbox: [6.752, 45.87, 7.052, 46.09],
    });
  });

  it('strips a leading prefix when place_formatted is used', async () => {
    mockFetch([peakFeature]);
    const results = await geocode('mount rainier');
    expect(results[0].region).toBe('WA, United States of America');
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