import { MAPTILER_API_KEY } from './config';

/** Place types the app surfaces in search: municipalities, towns, peaks/POIs, and mountain ranges. */
export const GEOCODE_TYPES = 'municipality,place,locality,poi,major_landform';
const DEFAULT_LIMIT = 6;

export interface GeocodeOptions {
  limit?: number;
  /** Current map position (lon/lat); the API biases result ranking toward it. */
  proximity?: { lon: number; lat: number };
}

export interface GeocodeResult {
  id: string;
  name: string;
  region: string;
  typeLabel: string;
  /** Peak summit elevation in meters, when the feature is a peak. */
  elevation?: number;
  center: { lon: number; lat: number };
  bbox?: [number, number, number, number];
}

interface RawPropertyTags { natural?: string; ele?: string; }
interface RawContext { id?: string; text?: string; country_code?: string; }
interface RawProperties {
  place_designation?: string;
  categories?: string[];
  feature_tags?: RawPropertyTags;
}
interface RawFeature {
  id?: string;
  text?: string;
  place_name?: string;
  place_formatted?: string;
  place_type?: string[];
  properties?: RawProperties;
  context?: RawContext[];
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

const SETTLEMENT_TYPES = new Set(['municipality', 'place', 'locality']);
const SHORT_COUNTRY: Record<string, string> = { 'United States': 'USA', 'United Kingdom': 'UK' };

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

/** Compact country label, e.g. "United States" → "USA". */
function countryLabel(context: RawContext | undefined): string {
  const text = context?.text ?? '';
  return SHORT_COUNTRY[text] ?? text;
}

/**
 * Administrative region from the feature's context hierarchy. `place_name` for
 * peaks/POIs often drops the state/province ("Little Bear Peak, Alamosa, United
 * States"), so rebuild it from the county/region/country context instead →
 * "Alamosa, Colorado, USA".
 */
function regionFromContext(context: RawContext[] = []): string {
  const county = context.find((entry) => entry.id?.startsWith('county.'))?.text;
  const region = context.find((entry) => entry.id?.startsWith('region.'))?.text;
  const country = context.find((entry) => entry.id?.startsWith('country.'));
  const parts = [county, region, country ? countryLabel(country) : ''].filter(Boolean);
  return parts.join(', ');
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
  const properties = feature.properties;
  const isSettlement = SETTLEMENT_TYPES.has(type ?? '');
  const region = isSettlement ? regionText(name, placeName) : regionFromContext(feature.context);
  const natural = properties?.feature_tags?.natural;
  const isPeak = natural === 'peak' || (properties?.categories ?? []).some((category) => category === 'peak');
  const typeLabel = isPeak ? 'Peak' : placeTypeLabel(type, properties?.place_designation);
  const elevation = isPeak ? parseElevation(properties?.feature_tags?.ele) : undefined;
  const bbox = feature.bbox && feature.bbox.length >= 4 ? (feature.bbox.slice(0, 4) as [number, number, number, number]) : undefined;
  return {
    id: feature.id ?? `${lon},${lat}`,
    name,
    region,
    typeLabel,
    elevation,
    center: { lon, lat },
    bbox,
  };
}

/** Parse MapTiler's elevation tag (meters, as a string) to a number; undefined when absent/invalid. */
function parseElevation(ele: string | undefined): number | undefined {
  if (ele === undefined) return undefined;
  const meters = Number(ele);
  return Number.isFinite(meters) && meters > 0 ? meters : undefined;
}

const round5 = (value: number) => Number(value.toFixed(5));

export function geocodeUrl(query: string, options: GeocodeOptions = {}): string {
  const { limit = DEFAULT_LIMIT, proximity } = options;
  const params = [`key=${encodeURIComponent(MAPTILER_API_KEY)}`, `limit=${limit}`, `types=${GEOCODE_TYPES}`];
  if (proximity) params.push(`proximity=${round5(proximity.lon)},${round5(proximity.lat)}`);
  return `https://api.maptiler.com/geocoding/${encodeURIComponent(query.trim())}.json?${params.join('&')}`;
}

/** Forward-geocode a query; returns [] on empty input, HTTP errors, or network failure. */
export async function geocode(query: string, options: GeocodeOptions = {}): Promise<GeocodeResult[]> {
  if (!query.trim()) return [];
  try {
    const response = await fetch(geocodeUrl(query, options));
    if (!response.ok) return [];
    const data: { features?: RawFeature[] } = (await response.json()) as { features?: RawFeature[] };
    return (data.features ?? []).flatMap((feature) => normalizeFeature(feature) ?? []);
  } catch {
    return [];
  }
}