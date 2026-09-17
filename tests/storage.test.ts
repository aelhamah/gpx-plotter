// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { clearWorkspace, loadWorkspace, saveWorkspace, STORAGE_KEY, STORAGE_VERSION } from '../src/storage';

const workspace = {
  routes: [{ id: 1, name: 'Loop', points: [{ lat: 1, lon: 2 }], color: '#e11d48' }],
  waypoints: [{ lat: 3, lon: 4, name: 'Camp' }],
  nextRouteId: 2,
  documentName: 'Alpine Lakes',
  selectedRouteId: 1,
  unitSystem: 'imperial' as const,
  view: { center: { lng: -105, lat: 38 }, zoom: 12, bearing: -12, pitch: 40 },
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
    });
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