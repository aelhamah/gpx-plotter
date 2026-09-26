import { describe, expect, it } from 'vitest';
import { haversineMeters } from '../src/geo';
import { accuracyCirclePolygon, locateButtonLabel, locateErrorMessage, locateUnavailableMessage, locationGeoJSON, zoomForAccuracy, type LocationFix } from '../src/locate';

const FIX: LocationFix = { lon: -106.5, lat: 39.5, accuracyMeters: 20, at: 0 };

describe('locateErrorMessage', () => {
  it('tells the user how to re-enable a denied permission', () => {
    expect(locateErrorMessage(1)).toMatch(/permission denied/i);
    expect(locateErrorMessage(1)).toMatch(/browser settings/i);
  });
  it('distinguishes unavailable, timed out, and unknown failures', () => {
    expect(locateErrorMessage(2)).toMatch(/unavailable/i);
    expect(locateErrorMessage(3)).toMatch(/timed out/i);
    expect(locateErrorMessage(99)).toMatch(/could not determine/i);
  });
});

describe('locateUnavailableMessage', () => {
  it('mentions HTTPS for insecure contexts', () => {
    expect(locateUnavailableMessage('insecure')).toMatch(/https/i);
  });
  it('reports unsupported browsers', () => {
    expect(locateUnavailableMessage('unsupported')).toMatch(/does not support/i);
  });
});

describe('locateButtonLabel', () => {
  it('invites the first lookup and refreshes after a fix', () => {
    expect(locateButtonLabel(null, 'prompt', false)).toBe('my location');
    expect(locateButtonLabel(null, 'granted', true)).toBe('update my location');
  });
  it('explains a denied or unavailable permission', () => {
    expect(locateButtonLabel(null, 'denied', true)).toMatch(/allow it/i);
    expect(locateButtonLabel('insecure', 'granted', false)).toMatch(/https/i);
    expect(locateButtonLabel('unsupported', 'granted', false)).toMatch(/unavailable/i);
  });
});

describe('accuracyCirclePolygon', () => {
  it('produces a closed ring at the requested radius', () => {
    const ring = accuracyCirclePolygon(FIX.lon, FIX.lat, 100).geometry.coordinates[0] as [number, number][];
    expect(ring.length).toBe(65);
    expect(ring[0]).toEqual(ring[ring.length - 1]);
    for (const [lon, lat] of ring) {
      expect(Math.abs(haversineMeters({ lon, lat }, FIX) - 100)).toBeLessThan(0.5);
    }
  });
  it('is bigger for a larger accuracy radius', () => {
    const radius = (meters: number) => {
      const ring = accuracyCirclePolygon(FIX.lon, FIX.lat, meters).geometry.coordinates[0] as [number, number][];
      return Math.max(...ring.map(([lon, lat]) => haversineMeters({ lon, lat }, FIX)));
    };
    expect(radius(10)).toBeLessThan(radius(1000));
  });
  it('keeps longitudes wrapped around the antimeridian', () => {
    const ring = accuracyCirclePolygon(179.999, 0, 2000).geometry.coordinates[0] as [number, number][];
    for (const [lon] of ring) {
      expect(lon).toBeGreaterThanOrEqual(-180);
      expect(lon).toBeLessThanOrEqual(180);
      expect(Math.min(Math.abs(lon - 180), Math.abs(lon + 180))).toBeLessThan(0.03);
    }
  });
});

describe('locationGeoJSON', () => {
  it('is empty without a fix', () => {
    expect(locationGeoJSON(null).features).toEqual([]);
  });
  it('emits a point plus an accuracy polygon', () => {
    const features = locationGeoJSON(FIX).features;
    expect(features.map((feature) => feature.geometry.type)).toEqual(['Point', 'Polygon']);
    expect(features[0].geometry).toEqual({ type: 'Point', coordinates: [FIX.lon, FIX.lat] });
  });
  it('drops the halo when accuracy is unknown', () => {
    expect(locationGeoJSON({ ...FIX, accuracyMeters: 0 }).features).toHaveLength(1);
  });
});

describe('zoomForAccuracy', () => {
  it('zooms in for a tighter fix', () => {
    expect(zoomForAccuracy(10, 39.5)).toBeGreaterThan(zoomForAccuracy(1000, 39.5));
  });
  it('zooms out for a wider fix', () => {
    expect(zoomForAccuracy(5000, 39.5)).toBeLessThan(zoomForAccuracy(50, 39.5));
  });
  it('clamps to the given maximum', () => {
    expect(zoomForAccuracy(5, 39.5)).toBe(15);
    expect(zoomForAccuracy(5, 39.5, 12)).toBe(12);
  });
  it('never drops below a usable zoom', () => {
    expect(zoomForAccuracy(500000, 39.5)).toBeGreaterThanOrEqual(2);
  });
  it('falls back to a street-level zoom for a missing accuracy', () => {
    expect(zoomForAccuracy(Number.NaN, 39.5)).toBe(zoomForAccuracy(30, 39.5));
    expect(zoomForAccuracy(0, 39.5)).toBe(zoomForAccuracy(30, 39.5));
  });
  it('zooms in further at the equator, where a fixed radius spans fewer pixels', () => {
    expect(zoomForAccuracy(1000, 0)).toBeGreaterThan(zoomForAccuracy(1000, 70));
  });
});
