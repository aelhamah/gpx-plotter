import { describe, it, expect } from 'vitest';
import {
  MAP_STYLE_URL,
  SATELLITE_STYLE_URL,
  TERRAIN_URL,
  TERRAIN_TILE_URL,
  TILE_PROXY_BASE_URL,
  TILE_PROXY_HOST,
} from '../src/config';

describe('map style & terrain config', () => {
  it('points the base and satellite styles at the expected MapTiler maps', () => {
    expect(MAP_STYLE_URL).toContain('/maps/outdoor-v2/');
    expect(SATELLITE_STYLE_URL).toContain('/maps/satellite-v4/');
  });
  it('wires terrain to a raster-dem tileset (so 3D drapes over imagery)', () => {
    expect(TERRAIN_URL).toContain('terrain-rgb');
    expect(TERRAIN_TILE_URL).toContain('terrain-rgb');
    expect(TERRAIN_TILE_URL).toContain('{z}/{x}/{y}');
  });
  it('serves every map resource over https', () => {
    for (const url of [MAP_STYLE_URL, SATELLITE_STYLE_URL, TERRAIN_URL, TERRAIN_TILE_URL]) {
      expect(url.startsWith('https://')).toBe(true);
    }
  });

  /**
   * The property this module exists for. A key in the bundle is readable by
   * anyone who loads the page, which is the leak the proxy was built to close.
   */
  it('puts no key in any URL', () => {
    for (const url of [MAP_STYLE_URL, SATELLITE_STYLE_URL, TERRAIN_URL, TERRAIN_TILE_URL]) {
      expect(url).not.toContain('key=');
      expect(url).not.toContain('maptiler');
    }
  });

  it('points every URL at the tile proxy', () => {
    expect(TILE_PROXY_BASE_URL).toBe('https://proxy.test');
    expect(TILE_PROXY_HOST).toBe('proxy.test');
    for (const url of [MAP_STYLE_URL, SATELLITE_STYLE_URL, TERRAIN_URL, TERRAIN_TILE_URL]) {
      expect(url.startsWith(TILE_PROXY_BASE_URL)).toBe(true);
    }
  });
});