export const ROUTE_COLORS = ['#e11d48', '#2563eb', '#16a34a', '#d97706', '#9333ea', '#0f766e', '#dc2626'];

/** Hover-trace highlight on the map; kept distinct from every route default color. */
export const TRACE_COLOR = '#0ea5e9';

/** Deterministic palette pick for a 1-based route id, wrapping when routes outnumber colors. */
export function routeColorForId(id: number): string {
  return ROUTE_COLORS[(((id - 1) % ROUTE_COLORS.length) + ROUTE_COLORS.length) % ROUTE_COLORS.length];
}