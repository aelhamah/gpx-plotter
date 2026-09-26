import type { Feature, FeatureCollection, Point, Polygon } from 'geojson';

/** Where the browser's geolocation permission currently stands. */
export type LocatePermission = 'granted' | 'prompt' | 'denied';

/** Why geolocation cannot be used at all, regardless of permission. */
export type LocateUnavailable = 'unsupported' | 'insecure';

/** One position report, decoupled from the DOM `GeolocationPosition`. */
export interface LocationFix { lon: number; lat: number; accuracyMeters: number; at: number; }

const EARTH_RADIUS_M = 6371008.8;
/** Web Mercator ground resolution at the equator, in meters per pixel at zoom 0. */
const METERS_PER_PIXEL_AT_ZOOM_0 = 156543.03392;
/** How wide the accuracy circle should be on screen when the camera moves to the fix. */
const TARGET_ACCURACY_PIXELS = 60;
const MIN_LATITUDE_FOR_SCALE = 1;
const DEFAULT_ACCURACY_METERS = 30;

/** `GeolocationPositionError` codes, spelled out so callers don't repeat magic numbers. */
export const PERMISSION_DENIED = 1;
export const POSITION_UNAVAILABLE = 2;
export const TIMEOUT = 3;

/**
 * Status-line copy for a failed position request. Permission failures spell out
 * how to re-enable it, since the browser will not re-prompt once it is denied.
 */
export function locateErrorMessage(code: number): string {
  if (code === PERMISSION_DENIED) {
    return 'Location permission denied — allow location for this site in your browser settings, then press the button again.';
  }
  if (code === POSITION_UNAVAILABLE) {
    return 'Your location is unavailable — check that location services are on, then try again.';
  }
  if (code === TIMEOUT) {
    return 'Locating timed out — try again somewhere with a clearer view of the sky.';
  }
  return 'Could not determine your location — try again in a moment.';
}

/** Status-line copy for browsers/contexts where geolocation can never succeed. */
export function locateUnavailableMessage(reason: LocateUnavailable): string {
  return reason === 'insecure'
    ? 'Location needs a secure connection — open this page over HTTPS (localhost also works).'
    : 'This browser does not support location lookup.';
}

/** Tooltip/aria copy for the locate button, given why it may be unusable and the last fix. */
export function locateButtonLabel(unavailable: LocateUnavailable | null, permission: LocatePermission, located: boolean): string {
  if (unavailable === 'insecure') return 'location needs an HTTPS connection';
  if (unavailable === 'unsupported') return 'location unavailable in this browser';
  if (permission === 'denied') return 'location blocked — allow it in your browser settings';
  return located ? 'update my location' : 'my location';
}

/**
 * Geodesic ring of `radiusMeters` around a point, for the accuracy halo. A
 * polygon (rather than a zoom-scaled circle layer) keeps the halo honest about
 * how far the fix can be off at any zoom.
 */
export function accuracyCirclePolygon(lon: number, lat: number, radiusMeters: number, steps = 64): Feature<Polygon> {
  const ring: [number, number][] = [];
  const distance = Math.max(0, radiusMeters);
  const latRad = lat * Math.PI / 180;
  const sinLat = Math.sin(latRad);
  const cosLat = Math.cos(latRad);
  const angular = distance / EARTH_RADIUS_M;
  for (let i = 0; i <= steps; i++) {
    const bearing = (i / steps) * Math.PI * 2;
    const sinLat2 = sinLat * Math.cos(angular) + cosLat * Math.sin(angular) * Math.cos(bearing);
    const lat2 = Math.asin(Math.min(1, Math.max(-1, sinLat2)));
    const lon2 = Math.atan2(Math.sin(bearing) * Math.sin(angular) * cosLat, Math.cos(angular) - sinLat * sinLat2);
    ring.push([wrapLongitude(lon + (lon2 * 180) / Math.PI), (lat2 * 180) / Math.PI]);
  }
  return { type: 'Feature', properties: {}, geometry: { type: 'Polygon', coordinates: [ring] } };
}

/** Point + accuracy halo for the `location` source; empty once the fix is cleared. */
export function locationGeoJSON(fix: LocationFix | null): FeatureCollection<Point | Polygon> {
  if (!fix) return { type: 'FeatureCollection', features: [] };
  const features: (Feature<Point> | Feature<Polygon>)[] = [
    { type: 'Feature', properties: {}, geometry: { type: 'Point', coordinates: [fix.lon, fix.lat] } },
  ];
  if (Number.isFinite(fix.accuracyMeters) && fix.accuracyMeters > 0) {
    features.push(accuracyCirclePolygon(fix.lon, fix.lat, fix.accuracyMeters));
  }
  return { type: 'FeatureCollection', features };
}

/**
 * Zoom that frames the accuracy halo in roughly `TARGET_ACCURACY_PIXELS` pixels,
 * clamped to `maxZoom`. A bad (or missing) accuracy reading falls back to a
 * street-level zoom so the dot is still worth showing.
 */
export function zoomForAccuracy(accuracyMeters: number, latitude: number, maxZoom = 15): number {
  const accuracy = Number.isFinite(accuracyMeters) && accuracyMeters > 0 ? accuracyMeters : DEFAULT_ACCURACY_METERS;
  const scale = Math.cos(Math.max(-90 + MIN_LATITUDE_FOR_SCALE, Math.min(90 - MIN_LATITUDE_FOR_SCALE, latitude)) * Math.PI / 180);
  const zoom = Math.log2((TARGET_ACCURACY_PIXELS * METERS_PER_PIXEL_AT_ZOOM_0 * Math.abs(scale)) / accuracy);
  return Math.round(Math.min(maxZoom, Math.max(2, zoom)) * 10) / 10;
}

function wrapLongitude(lon: number): number {
  return ((((lon + 180) % 360) + 360) % 360) - 180;
}
