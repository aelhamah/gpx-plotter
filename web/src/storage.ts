import type { UnitSystem } from './geo';
import type { Route, Waypoint } from './gpx';

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