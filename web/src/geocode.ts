import { TILE_PROXY_BASE_URL } from './config';
import { reportServiceFailure } from './serviceStatus';
import { haversineMeters } from './geo';

/**
 * Place types the app surfaces in search: municipalities, towns, peaks/POIs,
 * mountain ranges, and `address`. MapTiler indexes named trails, paths, and
 * backcountry roads under `address` (kind `street`), so including it is what
 * makes trail names ("Boneyard Trail") and places like "Lead King Basin Road"
 * searchable. Named trails are relabeled "Trail" in `normalizeFeature`.
 */
export const GEOCODE_TYPES = 'municipality,place,locality,poi,major_landform,address';

/**
 * The API's maximum. A whole-query search (see `geocodeUrl`) rings the limit
 * with exact matches — "Grand Canyon" returns nine near-identical POIs — and
 * `rankSearchResults` needs that pool both to collapse duplicates and to pick
 * the instance nearest the map, so the API is asked for everything it can give.
 */
const DEFAULT_LIMIT = 10;

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
  /** MapTiler's score for how well the name matches the query, when it sent one. */
  relevance?: number;
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
  /** MapTiler's whole-query match score, 0–1; absent on some failures. */
  relevance?: number;
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

/** Named trails/paths are indexed as `address` features; this flags the trail-like ones. */
const TRAIL_NAME = /trail|path|loop|greenway|walkway|footpath/i;
/** Trailheads are POIs whose name contains "trailhead". */
const TRAILHEAD_NAME = /trailhead/i;

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
  const isAddress = feature.place_type?.includes('address') ?? false;
  const isTrail = isAddress && TRAIL_NAME.test(name);
  const isSettlement = SETTLEMENT_TYPES.has(type ?? '');
  const region = isSettlement ? regionText(name, placeName) : regionFromContext(feature.context);
  const natural = properties?.feature_tags?.natural;
  const isPeak = natural === 'peak' || (properties?.categories ?? []).some((category) => category === 'peak');
  const isTrailhead = !isPeak && type === 'poi' && TRAILHEAD_NAME.test(name);
  const typeLabel = isPeak
    ? 'Peak'
    : isTrailhead
      ? 'Trailhead'
      : isTrail
        ? 'Trail'
        : isAddress
          ? 'Street'
          : placeTypeLabel(type, properties?.place_designation);
  const elevation = isPeak ? parseElevation(properties?.feature_tags?.ele) : undefined;
  const bbox = feature.bbox && feature.bbox.length >= 4 ? (feature.bbox.slice(0, 4) as [number, number, number, number]) : undefined;
  return {
    id: feature.id ?? `${lon},${lat}`,
    name,
    region,
    typeLabel,
    relevance: Number.isFinite(feature.relevance) ? feature.relevance : undefined,
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

/**
 * Relevance the API gives an exact name match. Legit matches ("Half Dome",
 * "Appalachian Trail", "Death Valley National Park") score 0.96 or 1.0; loose
 * word matches — the parking lots and same-name creeks a decorated query
 * attracts — land well below. Anything under this is worth one more try.
 */
export const STRONG_MATCH_RELEVANCE = 0.9;

/**
 * Words that decorate a park or land designation without naming it.
 *
 * OSM — MapTiler's source — names "Rock Creek National Park" "Rock Creek
 * Park": the user's "National" sits outside the indexed name, and a whole-query
 * score reflects that. Dropping one such word is what nudges the query onto the
 * name the index actually has.
 */
const DECORATIVE_WORDS = new Set([
  'national', 'state', 'provincial', 'regional', 'county',
  'recreation', 'conservation', 'wilderness', 'wildlife',
  'monument', 'memorial', 'historic', 'historical',
  'park', 'parks', 'forest', 'forests', 'preserve', 'refuge', 'reserve', 'reserves',
  'area', 'areas',
]);

/**
 * The query with its first decorative word dropped, or null when there is
 * nothing left to ask — no decorative word, or nothing but decoration after
 * dropping one ("National Park" asks no place in particular).
 */
export function relaxedQuery(query: string): string | null {
  const words = query.trim().split(/\s+/);
  const index = words.findIndex((word) => DECORATIVE_WORDS.has(word.toLowerCase()));
  if (index < 0) return null;
  const relaxed = [...words.slice(0, index), ...words.slice(index + 1)];
  const asksSomething = relaxed.some((word) => !DECORATIVE_WORDS.has(word.toLowerCase()));
  return asksSomething ? relaxed.join(' ') : null;
}

/** The API's score for its best answer in a result set, 0 when it had none. */
function topRelevance(results: GeocodeResult[]): number {
  return Math.max(0, ...results.map((result) => result.relevance ?? 0));
}

/**
 * Forward-geocode a query, and if the API's best answer is loose, ask again
 * without the query's decoration.
 *
 * Whole-query scoring (see `geocodeUrl`) finds an exact indexed name, but users
 * type official designations — "Rock Creek National Park" — that the index
 * does not carry ("Rock Creek Park"). Without a word to answer to, the query
 * scores 0.69 and attracts parking lots, while dropping the stray "National"
 * scores 1.0 and finds the park first. So: score as asked; if the best match
 * is weak and the query has a decorative word, drop the first one and score
 * again — twice — and keep whichever set the API matched more strongly. The
 * replacement is deliberate rather than interleaved: a weaker set from the
 * decorated query is noise around the answer the relaxed query already gives.
 *
 * At most two retries, so a miss costs at most three requests behind the same
 * debounce keystroke; anything already scoring STRONG_MATCH_RELEVANCE or
 * better is returned untouched, and unchanged.
 */
export async function geocodeWithFallback(query: string, options: GeocodeOptions = {}): Promise<GeocodeResult[]> {
  if (!query.trim()) return [];
  let asked = query;
  let best = await geocode(query, options);
  let bestScore = topRelevance(best);
  for (let attempt = 0; attempt < 2 && bestScore < STRONG_MATCH_RELEVANCE; attempt++) {
    const relaxed = relaxedQuery(asked);
    if (!relaxed || relaxed === asked) break;
    asked = relaxed;
    const retry = await geocode(relaxed, options);
    const retryScore = topRelevance(retry);
    if (retryScore > bestScore) {
      best = retry;
      bestScore = retryScore;
    }
  }
  return best;
}

/**
 * Goes to the tile proxy, which holds the key — see `config.ts`.
 *
 * No `key=` parameter: the proxy adds it upstream. A key in a query string ends
 * up in the proxy's access logs, in anything else that logs URLs, and in this
 * page's history entry.
 *
 * `autocomplete=false` scores the *whole* query. MapTiler's default is
 * autocomplete mode, which assumes the query is still being typed letter by
 * letter — the right assumption for a keystroke-driven box, the wrong one here,
 * where a 250 ms debounce sends completed words only. The difference is not
 * cosmetic: typed whole, "Rock Creek National Park" scored National Zoo parking
 * lots above Rock Creek Park, because autocomplete matched the loose words
 * "National" and "Park" against them while the park itself never had a word to
 * answer to. Whole-query scoring finds it.
 */
export function geocodeUrl(query: string, options: GeocodeOptions = {}): string {
  const { limit = DEFAULT_LIMIT, proximity } = options;
  const params = [`limit=${limit}`, `types=${GEOCODE_TYPES}`, 'autocomplete=false'];
  if (proximity) params.push(`proximity=${round5(proximity.lon)},${round5(proximity.lat)}`);
  const base = TILE_PROXY_BASE_URL.replace(/\/+$/, '');
  return `${base}/geocoding/${encodeURIComponent(query.trim())}.json?${params.join('&')}`;
}

/**
 * Order results for display, from the map's point of view.
 *
 * The API already biases by `proximity`, but softly — equal-relevance results
 * come back in whatever order the index happens to hold them. What the issue
 * calls for is nearer-wins *within* a relevance tier: several features share a
 * name ("Rock Creek Park" exists as a landform here, a place there), and the
 * one nearest what is on screen is the one the user means. Higher relevance
 * still outranks mere closeness — an exact far match beats a fuzzy near one —
 * so this only settles ties the API leaves open.
 *
 * Whole-query scoring also rings the limit with exact matches — "Grand Canyon"
 * returns nine near-identical POIs — and duplicates only push useful rows off
 * a fixed-sized list. Rows are collapsed on what the user can tell apart,
 * name and badge, keeping the best-ranked instance: for a sprawling feature
 * that is the occurrence closest to the map center.
 */
export function rankSearchResults(
  results: GeocodeResult[],
  center?: { lon: number; lat: number },
): GeocodeResult[] {
  const distanceFromCenter = center
    ? new Map<GeocodeResult, number>(results.map((result) => [
        result,
        haversineMeters({ lat: center.lat, lon: center.lon }, { lat: result.center.lat, lon: result.center.lon }),
      ]))
    : undefined;

  const ranked = distanceFromCenter
    ? [...results].sort((a, b) =>
        (b.relevance ?? Number.NEGATIVE_INFINITY) - (a.relevance ?? Number.NEGATIVE_INFINITY)
        || distanceFromCenter.get(a)! - distanceFromCenter.get(b)!)
    : [...results];

  const seen = new Set<string>();
  return ranked.filter((result) => {
    const key = `${result.name}\u0000${result.typeLabel}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/** Forward-geocode a query; returns [] on empty input, HTTP errors, or network failure. */
export async function geocode(query: string, options: GeocodeOptions = {}): Promise<GeocodeResult[]> {
  if (!query.trim()) return [];
  try {
    const response = await fetch(geocodeUrl(query, options));
    if (!response.ok) {
      // An empty result list and a dead endpoint look the same to the caller,
      // which would have the UI claim nothing matched a query it never sent.
      reportServiceFailure('search', `geocoding request failed with ${response.status}`);
      return [];
    }
    const data: { features?: RawFeature[] } = (await response.json()) as { features?: RawFeature[] };
    return (data.features ?? []).flatMap((feature) => normalizeFeature(feature) ?? []);
  } catch (error) {
    reportServiceFailure('search', error instanceof Error ? error.message : String(error));
    return [];
  }
}