import { defineConfig } from 'vitest/config';

/**
 * Test-only configuration.
 *
 * `src/config.ts` reads `VITE_TILE_PROXY_BASE_URL` at module load, so without
 * this every URL under test is built from an empty base string and the tests
 * pass for the wrong reason — `'/maps/outdoor-v2/style.json'` contains
 * `/maps/outdoor-v2/`, and a relative path is exactly what an unconfigured
 * deployment produces. Setting it here means the suite exercises a configured
 * build.
 *
 * Deliberately a separate file from `vite.config.ts`: this must never affect a
 * production build.
 */
export default defineConfig({
  test: {
    env: {
      VITE_TILE_PROXY_BASE_URL: 'https://proxy.test',
    },
  },
});