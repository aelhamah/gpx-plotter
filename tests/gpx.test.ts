// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { parseGPX, exportGPX } from '../src/gpx';

const route = (name: string, points: { lat: number; lon: number; elevation?: number }[] = []) => ({
  id: 1,
  name,
  points,
  color: '#e11d48',
});

describe('exportGPX → parseGPX round trip', () => {
  it('round-trips name and coordinates with elevation', () => {
    const xml = exportGPX(
      [route('Maroon Bells', [{ lat: 39.0998, lon: -106.9445, elevation: 2400.536 }, { lat: 39.1, lon: -106.945 }])],
      [],
    );
    expect(xml).toContain('creator="GPX Plotter"');
    const parsed = parseGPX(xml);
    expect(parsed.routes).toHaveLength(1);
    expect(parsed.routes[0].name).toBe('Maroon Bells');
    expect(parsed.routes[0].points).toHaveLength(2);
    expect(parsed.routes[0].points[0].lat).toBeCloseTo(39.0998, 6);
    expect(parsed.routes[0].points[0].lon).toBeCloseTo(-106.9445, 6);
    expect(parsed.routes[0].points[0].elevation).toBeCloseTo(2400.536, 2);
    expect(parsed.routes[0].points[1].elevation).toBeUndefined();
  });
  it('escapes XML-special characters in the name', () => {
    const xml = exportGPX([route('A & B <C/>', [{ lat: 0, lon: 0 }])], []);
    expect(xml).toContain('A &amp; B &lt;C/&gt;');
    expect(parseGPX(xml).routes[0].name).toBe('A & B <C/>');
  });
  it('exports multiple routes and waypoints together', () => {
    const xml = exportGPX(
      [
        route('First', [{ lat: 1, lon: 2 }, { lat: 3, lon: 4 }]),
        route('Second', [{ lat: 5, lon: 6 }, { lat: 7, lon: 8 }]),
      ],
      [{ lat: 9, lon: 10, name: 'Water' }],
    );
    const parsed = parseGPX(xml);
    expect(parsed.routes).toHaveLength(2);
    expect(parsed.routes.map((r) => r.name)).toEqual(['First', 'Second']);
    expect(parsed.waypoints).toHaveLength(1);
    expect(parsed.waypoints[0].name).toBe('Water');
    expect(parsed.waypoints[0].lat).toBe(9);
    expect(parsed.waypoints[0].lon).toBe(10);
  });
  it('round-trips a waypoint elevation when present', () => {
    const xml = exportGPX([], [{ lat: 9, lon: 10, name: 'Camp', elevation: 2134.5 }]);
    expect(xml).toContain('<ele>2134.50</ele>');
    const parsed = parseGPX(xml);
    expect(parsed.waypoints[0].elevation).toBeCloseTo(2134.5, 2);
  });
});

describe('parseGPX', () => {
  const sample = `<?xml version="1.0"?>
  <gpx version="1.1" creator="GPX Plotter" xmlns="http://www.topografix.com/GPX/1/1">
    <metadata><name>Lake Loop</name></metadata>
    <trk><name>Track One</name><trkseg>
      <trkpt lat="39.55" lon="-107.32"><ele>1750.5</ele></trkpt>
      <trkpt lat="39.551" lon="-107.318"><ele>1800.1</ele></trkpt>
    </trkseg></trk>
  </gpx>`;
  it('parses a track with elevations', () => {
    const parsed = parseGPX(sample);
    expect(parsed.routes).toHaveLength(1);
    expect(parsed.routes[0].name).toBe('Track One');
    expect(parsed.routes[0].points).toHaveLength(2);
    expect(parsed.routes[0].points[0].elevation).toBeCloseTo(1750.5, 6);
  });
  it('prefers track name over metadata name', () => {
    expect(parseGPX(sample).routes[0].name).toBe('Track One');
  });
  it('parses multiple tracks as separate routes', () => {
    const multi = `<?xml version="1.0"?>
      <gpx xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>A</name><trkseg><trkpt lat="1" lon="2"/><trkpt lat="3" lon="4"/></trkseg></trk>
        <trk><name>B</name><trkseg><trkpt lat="5" lon="6"/><trkpt lat="7" lon="8"/></trkseg></trk>
      </gpx>`;
    const parsed = parseGPX(multi);
    expect(parsed.routes.map((r) => r.name)).toEqual(['A', 'B']);
  });
  it('parses routes (rte) when no track exists', () => {
    const rte = `<?xml version="1.0"?>
      <gpx xmlns="http://www.topografix.com/GPX/1/1"><rte><name>Road Trip</name>
        <rtept lat="1" lon="2"/><rtept lat="3" lon="4"><ele>5</ele></rtept></rte></gpx>`;
    const parsed = parseGPX(rte);
    expect(parsed.routes).toHaveLength(1);
    expect(parsed.routes[0].name).toBe('Road Trip');
    expect(parsed.routes[0].points).toHaveLength(2);
    expect(parsed.routes[0].points[1].elevation).toBe(5);
  });
  it('parses waypoints into their own list', () => {
    const wps = `<?xml version="1.0"?>
      <gpx xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>T</name><trkseg><trkpt lat="1" lon="2"/><trkpt lat="3" lon="4"/></trkseg></trk>
        <wpt lat="9" lon="10"><name>Camp</name></wpt>
        <wpt lat="11" lon="12"/>
      </gpx>`;
    const parsed = parseGPX(wps);
    expect(parsed.waypoints).toHaveLength(2);
    expect(parsed.waypoints[0]).toEqual({ lat: 9, lon: 10, name: 'Camp' });
    expect(parsed.waypoints[1].name).toBe('Waypoint 2');
  });
  it('parses a waypoint elevation when supplied', () => {
    const wps = `<?xml version="1.0"?>
      <gpx xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>T</name><trkseg><trkpt lat="1" lon="2"/><trkpt lat="3" lon="4"/></trkseg></trk>
        <wpt lat="9" lon="10"><name>Camp</name><ele>1234.5</ele></wpt>
      </gpx>`;
    expect(parseGPX(wps).waypoints[0].elevation).toBeCloseTo(1234.5, 6);
  });
  it('throws on non-XML input', () => {
    expect(() => parseGPX('this is not xml')).toThrow();
  });
  it('throws on GPX with no points or waypoints', () => {
    expect(() => parseGPX('<gpx xmlns="http://www.topografix.com/GPX/1/1"></gpx>')).toThrow();
  });
});