/** Public browser configuration. Restrict the MapTiler key by HTTP origin. */
export const MAPTILER_API_KEY: string = import.meta.env.VITE_MAPTILER_API_KEY ?? '';

const key = encodeURIComponent(MAPTILER_API_KEY);
export const MAP_STYLE_URL = `https://api.maptiler.com/maps/outdoor-v2/style.json?key=${key}`;
export const SATELLITE_STYLE_URL = `https://api.maptiler.com/maps/satellite-v4/style.json?key=${key}`;
export const TERRAIN_URL = `https://api.maptiler.com/tiles/terrain-rgb-v2/tiles.json?key=${key}`;
export const TERRAIN_TILE_URL = `https://api.maptiler.com/tiles/terrain-rgb-v2/{z}/{x}/{y}.png?key=${key}`;

export const DEFAULT_CENTER: [number, number] = [-106.5, 39.5];
export const DEFAULT_ZOOM = 8;
