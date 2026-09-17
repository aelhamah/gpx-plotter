import { afterEach, describe, expect, it, vi } from 'vitest';
import { geocode, geocodeUrl, GEOCODE_TYPES, normalizeFeature, placeTypeLabel, type GeocodeResult } from '../src/geocode';

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

describe('geocodeUrl', () => {
  it('encodes the query and pins the key, type filter, and limit', () => {
    const url = geocodeUrl('Mount Rainier');
    expect(url.startsWith('https://api.maptiler.com/geocoding/Mount%20Rainier.json')).toBe(true);
    expect(url).toContain('key=');
    expect(url).toContain(`types=${GEOCODE_TYPES}`);
    expect(url).toContain('limit=6');
    expect(url).not.toContain('proximity=');
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
    expect(result?.bbox).toBeUndefined();
  });

  it('falls back to state + country when a peak has no county context', () => {
    expect(normalizeFeature(peakWithoutCounty)?.region).toBe('Colorado, USA');
  });

  it('omits elevation when the peak has no elevation tag', () => {
    expect(normalizeFeature(peakWithoutElevation)?.elevation).toBeUndefined();
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