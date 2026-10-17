// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import {
  clearCachedFix,
  clearWorkspace,
  isCachedFix,
  loadCachedFix,
  loadWorkspace,
  LOCATION_KEY,
  LOCATION_MAX_ACCURACY_METERS,
  LOCATION_MAX_AGE_MS,
  saveCachedFix,
  saveWorkspace,
  STORAGE_KEY,
  STORAGE_VERSION,
  type CachedFix,
} from '../src/storage';

const workspace = {
  routes: [{ id: 1, name: 'Loop', points: [{ lat: 1, lon: 2 }], color: '#e11d48' }],
  waypoints: [{ lat: 3, lon: 4, name: 'Camp' }],
  nextRouteId: 2,
  documentName: 'Alpine Lakes',
  selectedRouteId: 1,
  unitSystem: 'imperial' as const,
  view: { center: { lng: -105, lat: 38 }, zoom: 12, bearing: -12, pitch: 40 },
  snappingEnabled: false,
};

describe('workspace storage', () => {
  afterEach(() => localStorage.clear());

  it('round-trips a workspace through localStorage', () => {
    expect(saveWorkspace(workspace)).toBe(true);
    expect(loadWorkspace()).toEqual({ version: STORAGE_VERSION, ...workspace });
  });

  it('returns null when nothing has been saved', () => {
    expect(loadWorkspace()).toBeNull();
  });

  it('clears the saved workspace', () => {
    saveWorkspace(workspace);
    expect(clearWorkspace()).toBe(true);
    expect(loadWorkspace()).toBeNull();
  });

  it('returns null for corrupt JSON', () => {
    localStorage.setItem(STORAGE_KEY, '{nope');
    expect(loadWorkspace()).toBeNull();
  });

  it('returns null when the storage version does not match', () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ version: STORAGE_VERSION + 1, routes: [], waypoints: [] }));
    expect(loadWorkspace()).toBeNull();
  });

  it('rejects a payload whose routes/waypoints are not arrays', () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ version: STORAGE_VERSION, routes: {}, waypoints: 'nope' }));
    expect(loadWorkspace()).toBeNull();
  });

  it('fills sane defaults for missing optional fields', () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ version: STORAGE_VERSION, routes: [], waypoints: [], nextRouteId: -3 }));
    expect(loadWorkspace()).toEqual({
      version: STORAGE_VERSION,
      routes: [],
      waypoints: [],
      nextRouteId: 1,
      documentName: undefined,
      selectedRouteId: null,
      unitSystem: undefined,
      view: undefined,
      snappingEnabled: true,
    });
  });

  it('keeps snapping on for a workspace saved before the toggle existed', () => {
    // A missing field is not the same as an explicit `false`: everyone who used
    // the app before the toggle had snapping on, so upgrading must not silently
    // turn it off for them.
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ version: STORAGE_VERSION, routes: [], waypoints: [], nextRouteId: 1 }));
    expect(loadWorkspace()?.snappingEnabled).toBe(true);
  });

  it('remembers that the user turned snapping off', () => {
    saveWorkspace({ ...workspace, snappingEnabled: false });
    expect(loadWorkspace()?.snappingEnabled).toBe(false);
    saveWorkspace({ ...workspace, snappingEnabled: true });
    expect(loadWorkspace()?.snappingEnabled).toBe(true);
  });

  it('does not bump the storage version for the new field', () => {
    saveWorkspace(workspace);
    const raw = JSON.parse(localStorage.getItem(STORAGE_KEY)!);
    expect(raw.version).toBe(STORAGE_VERSION);
  });

  it('ignores partially malformed optional fields', () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
      version: STORAGE_VERSION,
      routes: [],
      waypoints: [],
      nextRouteId: 1,
      documentName: 42,
      unitSystem: 'furlongs',
      view: { center: { lng: 'x', lat: 38 }, zoom: 12, bearing: 0, pitch: 0 },
    }));
    expect(loadWorkspace()?.documentName).toBeUndefined();
    expect(loadWorkspace()?.unitSystem).toBeUndefined();
    expect(loadWorkspace()?.view).toBeUndefined();
  });

  it('survives a missing or blocked localStorage', () => {
    const original = Object.getOwnPropertyDescriptor(window, 'localStorage')!;
    Object.defineProperty(window, 'localStorage', { configurable: true, get() { throw new Error('blocked'); } });
    try {
      expect(saveWorkspace(workspace)).toBe(false);
      expect(loadWorkspace()).toBeNull();
      expect(clearWorkspace()).toBe(false);
    } finally {
      Object.defineProperty(window, 'localStorage', original);
    }
  });
});

/**
 * The cached position, which decides where the map opens. Deliberately keyed apart
 * from the workspace: it is where the device is, not the user's work, and a
 * workspace saved before it existed must still restore.
 */
describe('cached position storage', () => {
  const NOW = 1_700_000_000_000;
  const fix = (over: Partial<CachedFix> = {}): CachedFix => ({
    lon: -83.743,
    lat: 42.2808,
    at: NOW,
    accuracyMeters: 30,
    ...over,
  });

  afterEach(() => {
    localStorage.clear();
  });

  it('round-trips a position', () => {
    saveCachedFix(fix());
    expect(loadCachedFix(NOW)).toEqual(fix());
  });

  it('is absent until one is saved', () => {
    expect(loadCachedFix(NOW)).toBeNull();
  });

  /**
   * Separate keys, or clearing the user's routes would quietly also reset where the
   * map opens — and a stale workspace from before this existed would be rejected
   * as the wrong version, losing their routes.
   */
  it('lives under its own key, apart from the workspace', () => {
    saveWorkspace(workspace);
    saveCachedFix(fix());

    expect(loadCachedFix(NOW)).toEqual(fix());
    expect(loadWorkspace()?.routes).toHaveLength(1);
  });

  it('survives clearing the workspace, which is about work rather than place', () => {
    saveWorkspace(workspace);
    saveCachedFix(fix());

    clearWorkspace();

    expect(loadWorkspace()).toBeNull();
    expect(loadCachedFix(NOW)).toEqual(fix());
  });

  it('is forgotten by clearCachedFix', () => {
    saveCachedFix(fix());
    clearCachedFix();
    expect(loadCachedFix(NOW)).toBeNull();
  });

  describe('rejects a fix that is not usable', () => {
    it('ignores a corrupt body', () => {
      localStorage.setItem(LOCATION_KEY, 'not json');
      expect(loadCachedFix(NOW)).toBeNull();
    });

    it('ignores a position off the planet', () => {
      localStorage.setItem(LOCATION_KEY, JSON.stringify(fix({ lat: 91 })));
      expect(loadCachedFix(NOW)).toBeNull();
    });

    it('ignores one missing a coordinate', () => {
      localStorage.setItem(LOCATION_KEY, JSON.stringify({ lat: 42.2808, at: NOW }));
      expect(loadCachedFix(NOW)).toBeNull();
    });

    it('ignores one missing a timestamp', () => {
      localStorage.setItem(LOCATION_KEY, JSON.stringify({ lon: -83.743, lat: 42.2808 }));
      expect(loadCachedFix(NOW)).toBeNull();
    });
  });

  describe('how long a fix stays worth opening on', () => {
    it('keeps one from a long time ago, because people do not move at map scale', () => {
      expect(LOCATION_MAX_AGE_MS).toBeGreaterThan(30 * 24 * 60 * 60 * 1000);
      const old = fix({ at: NOW - (LOCATION_MAX_AGE_MS - 1000) });
      saveCachedFix(old);
      expect(loadCachedFix(NOW)).not.toBeNull();
    });

    it('drops one past the limit', () => {
      saveCachedFix(fix({ at: NOW - LOCATION_MAX_AGE_MS - 1000 }));
      expect(loadCachedFix(NOW)).toBeNull();
    });

    /** A restored device or a clock bug would otherwise make a fix immortal. */
    it('drops one from the future', () => {
      saveCachedFix(fix({ at: NOW + 60_000 }));
      expect(loadCachedFix(NOW)).toBeNull();
    });
  });

  /**
   * Some mobile networks return a "fix" with kilometres of accuracy, which is worse
   * than the city centroid it would otherwise be ranked above. The comparison has
   * to be made rather than assumed from the word "fix".
   */
  describe('accuracy', () => {
    it('keeps a precise fix', () => {
      saveCachedFix(fix({ accuracyMeters: 30 }));
      expect(loadCachedFix(NOW)).not.toBeNull();
    });

    it('drops one worse than the estimate it would outrank', () => {
      saveCachedFix(fix({ accuracyMeters: LOCATION_MAX_ACCURACY_METERS + 1 }));
      expect(loadCachedFix(NOW)).toBeNull();
    });

    it('keeps one that reported no accuracy at all', () => {
      // Absent is not the same as bad. The browser did not say, and refusing to
      // use it would send people to a city centroid for no stated reason.
      saveCachedFix(fix({ accuracyMeters: undefined }));
      expect(loadCachedFix(NOW)).not.toBeNull();
    });

    it('drops one whose accuracy is nonsense', () => {
      saveCachedFix(fix({ accuracyMeters: -5 }));
      expect(loadCachedFix(NOW)).toBeNull();
    });
  });

  it('refuses to save a fix it would not read back', () => {
    expect(saveCachedFix(fix({ lat: 91 }))).toBe(false);
    expect(loadCachedFix(NOW)).toBeNull();
  });

  it('validates a fix on its own', () => {
    expect(isCachedFix(fix())).toBe(true);
    expect(isCachedFix({ lon: 1, lat: 2 })).toBe(false);
    expect(isCachedFix(null)).toBe(false);
    expect(isCachedFix('42.2808')).toBe(false);
  });
});
