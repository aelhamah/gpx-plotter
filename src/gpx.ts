export interface RoutePoint {
  lat: number;
  lon: number;
  elevation?: number;
}

export interface Route {
  name: string;
  points: RoutePoint[];
}

function firstElement(parent: Element, tag: string): Element | null {
  return parent.getElementsByTagNameNS('*', tag)[0] ?? null;
}

function textOf(parent: Element, tag: string): string | undefined {
  return firstElement(parent, tag)?.textContent?.trim() || undefined;
}

export function parseGPX(xmlText: string): Route {
  const doc = new DOMParser().parseFromString(xmlText, 'application/xml');
  const parserError = doc.getElementsByTagName('parsererror')[0];
  if (parserError) throw new Error('The selected file is not valid XML/GPX.');

  const tracks = Array.from(doc.getElementsByTagNameNS('*', 'trk'));
  const routes = Array.from(doc.getElementsByTagNameNS('*', 'rte'));
  const points: RoutePoint[] = [];
  let name = textOf(doc.documentElement, 'name') ?? 'Imported Route';

  if (tracks.length) {
    name = textOf(tracks[0], 'name') ?? name;
    for (const track of tracks) {
      for (const segment of Array.from(track.getElementsByTagNameNS('*', 'trkseg'))) {
        for (const point of Array.from(segment.getElementsByTagNameNS('*', 'trkpt'))) {
          const lat = Number(point.getAttribute('lat'));
          const lon = Number(point.getAttribute('lon'));
          if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
          const eleText = textOf(point, 'ele');
          const elevation = eleText === undefined ? undefined : Number(eleText);
          points.push({ lat, lon, ...(Number.isFinite(elevation) ? { elevation } : {}) });
        }
      }
    }
  } else if (routes.length) {
    name = textOf(routes[0], 'name') ?? name;
    for (const point of Array.from(routes[0].getElementsByTagNameNS('*', 'rtept'))) {
      const lat = Number(point.getAttribute('lat'));
      const lon = Number(point.getAttribute('lon'));
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
      const eleText = textOf(point, 'ele');
      const elevation = eleText === undefined ? undefined : Number(eleText);
      points.push({ lat, lon, ...(Number.isFinite(elevation) ? { elevation } : {}) });
    }
  }

  if (!points.length) throw new Error('No track or route points were found in this GPX file.');
  return { name, points };
}

function xmlEscape(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

export function exportGPX(route: Route): string {
  const points = route.points.map((p) => {
    const elevation = p.elevation === undefined ? '' : `\n        <ele>${p.elevation.toFixed(2)}</ele>`;
    return `      <trkpt lat="${p.lat.toFixed(7)}" lon="${p.lon.toFixed(7)}">${elevation}\n      </trkpt>`;
  }).join('\n');

  return `<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="GPX Plotter" xmlns="http://www.topografix.com/GPX/1/1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">\n  <metadata>\n    <name>${xmlEscape(route.name || 'My Route')}</name>\n  </metadata>\n  <trk>\n    <name>${xmlEscape(route.name || 'My Route')}</name>\n    <trkseg>\n${points}\n    </trkseg>\n  </trk>\n</gpx>\n`;
}
