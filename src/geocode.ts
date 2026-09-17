import { MAPTILER_API_KEY } from './config';

/** Place types the app surfaces in search: municipalities, towns, peaks/POIs, and mountain ranges. */
export const GEOCODE_TYPES = 'municipality,place,locality,poi,major_landform';
const DEFAULT_LIMIT = 6;

export interface GeocodeResult {
  id: string;
  name: string;
  region: string;
  typeLabel: string;
  center: { lon: number; lat: number };
  bbox?: [number, number, number, number];
}

interface RawFeature {
  id?: string;
  text?: string;
  place_name?: string;
  place_formatted?: string;
  place_type?: string[];
  place_designation?: string;
  geometry?: { type?: string; coordinates?: unknown };
  bbox?: number[];
}

const TYPE_LABELS: Record<string, string> = {
  municipality: 'Municipality',
  locality: 'Locality',
  place: 'Place',
  poi: 'Point of interest',
  major_landform: 'Mountain range / landform',
  country: 'Country',
  region: 'Region',
  county: 'County',
  city: 'City',
  town: 'Town',
  village: 'Village',
  hamlet: 'Hamlet',
};

/** Human-friendly badge for a feature's kind; prefer the OSM place designation when known. */
export function placeTypeLabel(placeType: string | undefined, placeDesignation?: string): string {
  if (placeDesignation && TYPE_LABELS[placeDesignation]) return TYPE_LABELS[placeDesignation];
  if (placeType && TYPE_LABELS[placeType]) return TYPE_LABELS[placeType];
  return 'Place';
}

/** Short disambiguation text (context after the matched name). */
function regionText(name: string, placeName: string): string {
  if (!placeName) return '';
  if (name && placeName.startsWith(name)) {
    const rest = placeName.slice(name.length).replace(/^,\s*/, '');
    return rest || placeName;
  }
  return placeName;
}

/** Map a raw MapTiler geocoding feature to our normalized result; null when unusable. */
export function normalizeFeature(feature: RawFeature): GeocodeResult | null {
  const geometry = feature.geometry;
  if (!geometry || geometry.type !== 'Point') return null;
  if (!Array.isArray(geometry.coordinates) || geometry.coordinates.length < 2) return null;
  const [lon, lat] = geometry.coordinates as number[];
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;
  const placeName = feature.place_formatted ?? feature.place_name ?? '';
  const name = feature.text ?? placeName;
  const type = feature.place_type?.[0];
  const bbox = feature.bbox && feature.bbox.length >= 4 ? (feature.bbox.slice(0, 4) as [number, number, number, number]) : undefined;
  return {
    id: feature.id ?? `${lon},${lat}`,
    name,
    region: regionText(name, placeName),
    typeLabel: placeTypeLabel(type, feature.place_designation),
    center: { lon, lat },
    bbox,
  };
}

export function geocodeUrl(query: string, limit = DEFAULT_LIMIT): string {
  const encodedQuery = encodeURIComponent(query.trim());
  const key = encodeURIComponent(MAPTILER_API_KEY);
  return `https://api.maptiler.com/geocoding/${encodedQuery}.json?key=${key}&limit=${limit}&types=${GEOCODE_TYPES}`;
}

/** Forward-geocode a query; returns [] on empty input, HTTP errors, or network failure. */
export async function geocode(query: string, limit = DEFAULT_LIMIT): Promise<GeocodeResult[]> {
  if (!query.trim()) return [];
  try {
    const response = await fetch(geocodeUrl(query, limit));
    if (!response.ok) return [];
    const data: { features?: RawFeature[] } = (await response.json()) as { features?: RawFeature[] };
    return (data.features ?? []).flatMap((feature) => normalizeFeature(feature) ?? []);
  } catch {
    return [];
  }
}