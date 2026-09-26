import { metersToFeet, metersToKm, metersToMiles, type UnitSystem } from './geo';

/** Preferred units: imperial when the user's locale resolves to the US, metric otherwise. */
export function defaultUnitSystem(): UnitSystem {
  try {
    const region = new Intl.Locale(navigator.language).region;
    return region === 'US' ? 'imperial' : 'metric';
  } catch {
    return navigator.language.toLowerCase().startsWith('en-us') ? 'imperial' : 'metric';
  }
}

export function formatDistance(meters: number, system: UnitSystem): string {
  return system === 'imperial' ? `${metersToMiles(meters).toFixed(2)} mi` : `${metersToKm(meters).toFixed(2)} km`;
}

export function formatElevation(meters: number | undefined, system: UnitSystem): string {
  if (meters === undefined) return '—';
  return system === 'imperial'
    ? `${Math.round(metersToFeet(meters)).toLocaleString()} ft`
    : `${Math.round(meters).toLocaleString()} m`;
}

export function formatSlope(degrees: number | undefined): string {
  return degrees === undefined ? '—' : `${Math.round(degrees)}°`;
}

export function formatDistanceAxis(meters: number, system: UnitSystem): string {
  const value = system === 'imperial' ? metersToMiles(meters) : metersToKm(meters);
  return value < 10 ? value.toFixed(1) : Math.round(value).toString();
}

/** Position accuracy radius: metres/feet while it is small, km/miles once it is not. */
export function formatAccuracy(meters: number, system: UnitSystem): string {
  if (!Number.isFinite(meters) || meters <= 0) return '—';
  return system === 'imperial'
    ? (meters < 1609.344 ? `${Math.round(metersToFeet(meters))} ft` : `${metersToMiles(meters).toFixed(1)} mi`)
    : (meters < 1000 ? `${Math.round(meters)} m` : `${metersToKm(meters).toFixed(1)} km`);
}