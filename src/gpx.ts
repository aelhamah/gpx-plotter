import { normalizeWaypointName } from './names';

export interface RoutePoint {
  lat: number;
  lon: number;
  elevation?: number;
}

export interface Route {
  id: number;
  name: string;
  points: RoutePoint[];
  color: string;
}

export interface Waypoint {
  lat: number;
  lon: number;
  name: string;
  elevation?: number;
}

function firstElement(parent: Element, tag: string): Element | null {
  return parent.getElementsByTagNameNS('*', tag)[0] ?? null;
}

function textOf(parent: Element, tag: string): string | undefined {
  return firstElement(parent, tag)?.textContent?.trim() || undefined;
}

function pointFrom(node: Element): RoutePoint | null {
  const lat = Number(node.getAttribute('lat'));
  const lon = Number(node.getAttribute('lon'));
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  const eleText = textOf(node, 'ele');
  const elevation = eleText === undefined ? undefined : Number(eleText);
  return { lat, lon, ...(Number.isFinite(elevation) ? { elevation } : {}) };
}

export interface ParsedGPX {
  routes: { name: string; points: RoutePoint[] }[];
  waypoints: Waypoint[];
  /** The GPX <metadata><name>, when present — the file-level/map name. */
  metadataName?: string;
}

export function parseGPX(xmlText: string): ParsedGPX {
  const doc = new DOMParser().parseFromString(xmlText, 'application/xml');
  const parserError = doc.getElementsByTagName('parsererror')[0];
  if (parserError) throw new Error('The selected file is not valid XML/GPX.');

  const routes: { name: string; points: RoutePoint[] }[] = [];
  const waypoints: Waypoint[] = [];

  const tracks = Array.from(doc.getElementsByTagNameNS('*', 'trk'));
  const routeElems = Array.from(doc.getElementsByTagNameNS('*', 'rte'));
  if (tracks.length) {
    tracks.forEach((track, index) => {
      const points: RoutePoint[] = [];
      for (const segment of Array.from(track.getElementsByTagNameNS('*', 'trkseg'))) {
        for (const node of Array.from(segment.getElementsByTagNameNS('*', 'trkpt'))) {
          const point = pointFrom(node);
          if (point) points.push(point);
        }
      }
      routes.push({ name: textOf(track, 'name') ?? (tracks.length > 1 ? `Track ${index + 1}` : 'Imported Route'), points });
    });
  } else if (routeElems.length) {
    routeElems.forEach((route, index) => {
      const points: RoutePoint[] = [];
      for (const node of Array.from(route.getElementsByTagNameNS('*', 'rtept'))) {
        const point = pointFrom(node);
        if (point) points.push(point);
      }
      routes.push({ name: textOf(route, 'name') ?? (routeElems.length > 1 ? `Route ${index + 1}` : 'Imported Route'), points });
    });
  }

  Array.from(doc.getElementsByTagNameNS('*', 'wpt')).forEach((node, index) => {
    const point = pointFrom(node);
    if (!point) return;
    waypoints.push({
      lat: point.lat,
      lon: point.lon,
      name: normalizeWaypointName(textOf(node, 'name') ?? '', index),
      ...(point.elevation === undefined ? {} : { elevation: point.elevation }),
    });
  });

  const metadata = Array.from(doc.getElementsByTagNameNS('*', 'metadata'))[0];
  const metadataName = metadata ? textOf(metadata, 'name') : undefined;

  if (!routes.some((route) => route.points.length) && !waypoints.length) {
    throw new Error('No track, route, or waypoint data was found in this GPX file.');
  }
  return { routes: routes.filter((route) => route.points.length), waypoints, ...(metadataName ? { metadataName } : {}) };
}

function xmlEscape(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

export function exportGPX(routes: Route[], waypoints: Waypoint[], name?: string): string {
  const tracks = routes.map((route) => {
    const points = route.points.map((p) => {
      const elevation = p.elevation === undefined ? '' : `\n        <ele>${p.elevation.toFixed(2)}</ele>`;
      return `      <trkpt lat="${p.lat.toFixed(7)}" lon="${p.lon.toFixed(7)}">${elevation}\n      </trkpt>`;
    }).join('\n');
    return `  <trk>\n    <name>${xmlEscape(route.name || 'Unnamed route')}</name>\n    <trkseg>\n${points}\n    </trkseg>\n  </trk>`;
  }).join('\n');

  const wpts = waypoints.map((w) => {
    const elevation = w.elevation === undefined ? '' : `\n    <ele>${w.elevation.toFixed(2)}</ele>`;
    return `  <wpt lat="${w.lat.toFixed(7)}" lon="${w.lon.toFixed(7)}">\n    <name>${xmlEscape(w.name || 'Waypoint')}</name>${elevation}\n  </wpt>`;
  }).join('\n');

  const metadataName = xmlEscape(name ?? routes[0]?.name ?? 'My Route');
  return `<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="GPX Plotter" xmlns="http://www.topografix.com/GPX/1/1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">\n  <metadata>\n    <name>${metadataName}</name>\n  </metadata>\n${tracks ? `${tracks}\n` : ''}${wpts ? `${wpts}\n` : ''}</gpx>\n`;
}