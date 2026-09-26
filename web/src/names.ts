/** Shared fallbacks for user-editable route and waypoint names. */
export function normalizeRouteName(raw: string, id: number): string {
  return raw.trim() || `Route ${id}`;
}

export function normalizeWaypointName(raw: string, index: number): string {
  return raw.trim() || `Waypoint ${index + 1}`;
}