// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { parseGPX, exportGPX } from '../src/gpx';

describe('exportGPX → parseGPX round trip', () => {
  it('round-trips name and coordinates with elevation', () => {
    const route = { name: 'Maroon Bells', points: [{ lat: 39.0998, lon: -106.9445, elevation: 2400.536 }, { lat: 39.1, lon: -106.945 }] };
    const xml = exportGPX(route);
    expect(xml).toContain('creator="GPX Plotter"');
    const parsed = parseGPX(xml);
    expect(parsed.name).toBe('Maroon Bells');
    expect(parsed.points).toHaveLength(2);
    expect(parsed.points[0].lat).toBeCloseTo(39.0998, 6);
    expect(parsed.points[0].lon).toBeCloseTo(-106.9445, 6);
    expect(parsed.points[0].elevation).toBeCloseTo(2400.536, 2);
    expect(parsed.points[1].elevation).toBeUndefined();
  });
  it('escapes XML-special characters in the name', () => {
    const xml = exportGPX({ name: 'A & B <C/>', points: [{ lat: 0, lon: 0 }] });
    expect(xml).toContain('A &amp; B &lt;C/&gt;');
    expect(parseGPX(xml).name).toBe('A & B <C/>');
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
    const route = parseGPX(sample);
    expect(route.name).toBe('Track One');
    expect(route.points).toHaveLength(2);
    expect(route.points[0].elevation).toBeCloseTo(1750.5, 6);
  });
  it('prefers track name over metadata name', () => {
    expect(parseGPX(sample).name).toBe('Track One');
  });
  it('parses routes (rte) when no track exists', () => {
    const rte = `<?xml version="1.0"?>
      <gpx xmlns="http://www.topografix.com/GPX/1/1"><rte><name>Road Trip</name>
        <rtept lat="1" lon="2"/><rtept lat="3" lon="4"><ele>5</ele></rtept></rte></gpx>`;
    const route = parseGPX(rte);
    expect(route.name).toBe('Road Trip');
    expect(route.points).toHaveLength(2);
    expect(route.points[1].elevation).toBe(5);
  });
  it('throws on non-XML input', () => {
    expect(() => parseGPX('this is not xml')).toThrow();
  });
  it('throws on GPX with no points', () => {
    expect(() => parseGPX('<gpx xmlns="http://www.topografix.com/GPX/1/1"></gpx>')).toThrow();
  });
});