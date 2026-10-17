/**
 * Public browser configuration.
 *
 * ## Why there is no key here
 *
 * This used to read `VITE_MAPTILER_API_KEY` and put it in every URL, which put
 * it in the shipped JavaScript where anybody could read it out of the bundle.
 * The key now lives in the tile proxy's secrets (see `proxy/README.md`) and this
 * module carries only the proxy's address.
 *
 * The proxy adds the key upstream and strips it back out of every style and
 * TileJSON it serves, so following a rewritten source URL still works and still
 * reveals nothing.
 */
export const TILE_PROXY_BASE_URL: string = import.meta.env.VITE_TILE_PROXY_BASE_URL ?? '';

/** Trailing slashes stripped once here, so no path is built with a doubled slash. */
const base = TILE_PROXY_BASE_URL.replace(/\/+$/, '');

/**
 * The proxy's host, for classifying failures.
 *
 * `serviceStatus.ts` decides which of our dependencies a network error belongs
 * to by looking at the host in the message, and that host is now this one. It is
 * parsed from the URL rather than duplicated as its own variable so the two
 * cannot drift apart.
 */
export const TILE_PROXY_HOST: string = (() => {
  if (!base) return '';
  try {
    return new URL(base).host;
  } catch {
    return '';
  }
})();

export const MAP_STYLE_URL = `${base}/maps/outdoor-v2/style.json`;
export const SATELLITE_STYLE_URL = `${base}/maps/satellite-v4/style.json`;
export const TERRAIN_URL = `${base}/tiles/terrain-rgb-v2/tiles.json`;
export const TERRAIN_TILE_URL = `${base}/tiles/terrain-rgb-v2/{z}/{x}/{y}.png`;

/** Marked trail/routing vector tiles ("trail" layer) used to snap drawn points onto trails. */
export const OUTDOOR_TILE_URL = `${base}/tiles/outdoor/{z}/{x}/{y}.pbf`;
/** OpenMapTiles-planet vector tiles ("mountain_peak" layer) used to snap waypoints onto peaks. */
export const PLANET_TILE_URL = `${base}/tiles/v3/{z}/{x}/{y}.pbf`;

export const DEFAULT_CENTER: [number, number] = [-106.5, 39.5];
export const DEFAULT_ZOOM = 8;