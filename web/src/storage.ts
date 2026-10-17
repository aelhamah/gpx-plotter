import type { UnitSystem } from './geo';
import type { Route, Waypoint } from './gpx';
import { SNAP_ENABLED_BY_DEFAULT } from './snap';

export interface WorkspaceView {
  center: { lng: number; lat: number };
  zoom: number;
  bearing: number;
  pitch: number;
}

/** Everything that is kept across reloads for the current map/workspace. */
export interface PersistedWorkspace {
  version: number;
  routes: Route[];
  waypoints: Waypoint[];
  nextRouteId: number;
  documentName?: string;
  selectedRouteId?: number | null;
  unitSystem?: UnitSystem;
  view?: WorkspaceView;
  /** Absent means the user never chose, so snapping stays on. */
  snappingEnabled?: boolean;
}

export const STORAGE_KEY = 'gpx-plotter:workspace';
export const STORAGE_VERSION = 1;

/** Detect a working localStorage once and cache the result. */
function storageAvailable(): boolean {
  try {
    const probe = '__gpx_plotter_probe__';
    localStorage.setItem(probe, probe);
    localStorage.removeItem(probe);
    return true;
  } catch {
    return false;
  }
}

let availability: boolean | undefined;
function storageUsable(): boolean {
  if (availability === undefined) availability = storageAvailable();
  return availability;
}

export function isWorkspaceView(value: unknown): value is WorkspaceView {
  const view = value as WorkspaceView | undefined;
  return !!view && typeof view === 'object'
    && Number.isFinite(view.center?.lng) && Number.isFinite(view.center?.lat)
    && Number.isFinite(view.zoom) && Number.isFinite(view.bearing) && Number.isFinite(view.pitch);
}

/** Persist the current workspace. Returns false when storage is unavailable or full. */
export function saveWorkspace(data: Omit<PersistedWorkspace, 'version'>): boolean {
  if (!storageUsable()) return false;
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ version: STORAGE_VERSION, ...data }));
    return true;
  } catch {
    return false;
  }
}

/** Restore the saved workspace, or null when absent, corrupt, or from another version. */
export function loadWorkspace(): PersistedWorkspace | null {
  if (!storageUsable()) return null;
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<PersistedWorkspace>;
    if (!parsed || parsed.version !== STORAGE_VERSION) return null;
    if (!Array.isArray(parsed.routes) || !Array.isArray(parsed.waypoints)) return null;
    return {
      version: STORAGE_VERSION,
      routes: parsed.routes,
      waypoints: parsed.waypoints,
      nextRouteId: Number.isFinite(parsed.nextRouteId) && parsed.nextRouteId! > 0 ? parsed.nextRouteId as number : 1,
      documentName: typeof parsed.documentName === 'string' ? parsed.documentName : undefined,
      selectedRouteId: Number.isFinite(parsed.selectedRouteId as number) || parsed.selectedRouteId == null ? parsed.selectedRouteId ?? null : null,
      unitSystem: parsed.unitSystem === 'metric' || parsed.unitSystem === 'imperial' ? parsed.unitSystem : undefined,
      view: isWorkspaceView(parsed.view) ? parsed.view : undefined,
      // Only an explicit `false` turns snapping off. A workspace saved before the
      // toggle existed has no field at all, and that must not read as a choice.
      snappingEnabled: parsed.snappingEnabled !== false ? SNAP_ENABLED_BY_DEFAULT : false,
    };
  } catch {
    return null;
  }
}

/** Forget the saved workspace (used by the "Clear" flow). */
export function clearWorkspace(): boolean {
  if (!storageUsable()) return false;
  try {
    localStorage.removeItem(STORAGE_KEY);
    return true;
  } catch {
    return false;
  }
}

// MARK: - Cached position

/**
 * The last position the browser gave us, kept so the map can open somewhere
 * sensible before anyone presses the locate button.
 *
 * Separate from the workspace, and deliberately not cleared by "Clear all routes,
 * waypoints, and saved data": that button is about the user's *work*, and where
 * the device happens to be is neither their work nor something they asked to keep.
 * It also lives under its own key so a workspace from before this existed still
 * restores, rather than being rejected as the wrong version.
 */
export const LOCATION_KEY = 'gpx-plotter:last-location';

/**
 * How old a cached fix may be and still be worth opening on.
 *
 * Generous, because people do not move at map scale — a fix from last winter is
 * still a far better opening frame than a city centroid from an IP. But not
 * unlimited: someone who moved countries a year ago should get their estimate,
 * which at least follows them to the right continent.
 */
export const LOCATION_MAX_AGE_MS = 180 * 24 * 60 * 60 * 1000;

/**
 * The worst accuracy a cached fix may have and still be preferred over an IP
 * estimate.
 *
 * A "fix" with kilometres of accuracy is what some mobile networks return, and it
 * is *worse* than the city centroid it would otherwise be ranked above — so the
 * comparison is made explicitly rather than assuming the word "fix" means precise.
 */
export const LOCATION_MAX_ACCURACY_METERS = 5_000;

export interface CachedFix {
  lon: number;
  lat: number;
  /** `Date.now()` when it was taken. */
  at: number;
  /** Reported accuracy in meters; absent when the browser gave none. */
  accuracyMeters?: number;
}

export function isCachedFix(value: unknown): value is CachedFix {
  const fix = value as CachedFix | undefined;
  return !!fix && typeof fix === 'object'
    && Number.isFinite(fix.lon) && Number.isFinite(fix.lat)
    && Math.abs(fix.lat) <= 90 && Math.abs(fix.lon) <= 180
    && Number.isFinite(fix.at);
}

/** Remember a position. Returns false when storage is unavailable or full. */
export function saveCachedFix(fix: CachedFix): boolean {
  if (!storageUsable() || !isCachedFix(fix)) return false;
  try {
    localStorage.setItem(LOCATION_KEY, JSON.stringify(fix));
    return true;
  } catch {
    return false;
  }
}

/**
 * The cached position, or null when there is none worth opening on.
 *
 * Null covers a lot — absent, corrupt, from a future clock, too old, too vague —
 * because from the caller's side they are the same decision: open somewhere else.
 */
export function loadCachedFix(now = Date.now()): CachedFix | null {
  if (!storageUsable()) return null;
  let parsed: unknown;
  try {
    const raw = localStorage.getItem(LOCATION_KEY);
    if (!raw) return null;
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!isCachedFix(parsed)) return null;

  // A clock that has gone backwards — a restored device, a timezone bug — would
  // otherwise make a fix from the future immortal. Treated as unusable.
  const age = now - parsed.at;
  if (age < 0 || age > LOCATION_MAX_AGE_MS) return null;
  if (parsed.accuracyMeters !== undefined
    && (!Number.isFinite(parsed.accuracyMeters)
      || parsed.accuracyMeters < 0
      || parsed.accuracyMeters > LOCATION_MAX_ACCURACY_METERS)) {
    return null;
  }
  return parsed;
}

/** Forget the cached position. */
export function clearCachedFix(): boolean {
  if (!storageUsable()) return false;
  try {
    localStorage.removeItem(LOCATION_KEY);
    return true;
  } catch {
    return false;
  }
}