// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import {
  classifyServiceFailure,
  looksRateLimited,
  onServiceFailure,
  reportServiceFailure,
  ServiceStatus,
  summarizeServices,
  type ServiceIssue,
} from '../src/serviceStatus';

const STYLE_ERROR = 'AJAXError: Failed to fetch (0): https://api.maptiler.com/maps/outdoor-v2/style.json?key=abc';
const TILE_ERROR = 'AJAXError: Failed to fetch (0): https://api.maptiler.com/tiles/outdoor/3/1/2.pbf?key=abc';
const DEM_ERROR = 'Error: DEM tile 12/656/1583 failed with 429';

const issue = (kind: ServiceIssue['kind'], extra: Partial<ServiceIssue> = {}): ServiceIssue => ({
  kind,
  detail: '',
  rateLimited: false,
  count: 1,
  ...extra,
});

describe('classifyServiceFailure', () => {
  it('maps each service URL to the service that owns it', () => {
    expect(classifyServiceFailure(STYLE_ERROR)).toBe('style');
    expect(classifyServiceFailure(TILE_ERROR)).toBe('basemap');
    expect(classifyServiceFailure('https://api.maptiler.com/geocoding/summer.json?key=abc')).toBe('search');
    expect(classifyServiceFailure('https://api.maptiler.com/tiles/terrain-rgb-v2/12/656/1583.png?key=abc')).toBe('elevation');
  });

  it('recognises a DEM failure reported without a URL', () => {
    expect(classifyServiceFailure(DEM_ERROR)).toBe('elevation');
  });

  it('prefers the specific service over the shared host', () => {
    // Terrain and geocoding both live on api.maptiler.com; matching the host
    // first would blame the basemap for every terrain failure.
    expect(classifyServiceFailure('https://api.maptiler.com/tiles/terrain-rgb-v2/1/2/3.png')).toBe('elevation');
    expect(classifyServiceFailure('https://api.maptiler.com/geocoding/x.json')).toBe('search');
  });

  it('ignores failures the user cannot act on', () => {
    expect(classifyServiceFailure('AJAXError: Failed to fetch (0): https://events.mapbox.com/ingest')).toBeNull();
    expect(classifyServiceFailure('Failed to initialize WebGL2 context')).toBeNull();
    expect(classifyServiceFailure('')).toBeNull();
  });
});

describe('looksRateLimited', () => {
  it('spots an over-quota response', () => {
    expect(looksRateLimited('DEM tile 1/2/3 failed with 429')).toBe(true);
    expect(looksRateLimited('Too many requests for a Free plan.')).toBe(true);
  });

  it('does not mistake a plain network failure for one', () => {
    expect(looksRateLimited(DEM_ERROR.replace('429', '500'))).toBe(false);
    expect(looksRateLimited('Failed to fetch (0)')).toBe(false);
  });
});

describe('summarizeServices', () => {
  it('says nothing when nothing is broken', () => {
    expect(summarizeServices([])).toBeNull();
  });

  it('leads with a dead style, since it takes everything else with it', () => {
    const summary = summarizeServices([issue('search'), issue('style'), issue('elevation')]);
    expect(summary?.level).toBe('error');
    expect(summary?.text).toContain("Basemap won't load");
    expect(summary?.text.indexOf("Basemap won't load")).toBeLessThan(summary!.text.indexOf("Terrain won't load"));
  });

  it('treats tile noise as a warning, not an error', () => {
    expect(summarizeServices([issue('basemap')])?.level).toBe('warning');
    expect(summarizeServices([issue('elevation')])?.level).toBe('error');
  });

  it('warns rather than errors when snapping stops working', () => {
    // The basemap still draws and routes still compute, so this is a warning.
    const summary = summarizeServices([issue('snap')]);
    expect(summary?.level).toBe('warning');
    expect(summary?.text).toContain("Trails aren't snapping");
  });

  it('does not blame the basemap when only snapping failed', () => {
    // Snapping has its own tiles; the style is still perfectly healthy.
    const summary = summarizeServices([issue('snap')]);
    expect(summary?.text).not.toContain('basemap tiles');
  });

  it('leads with a dead style over a snapping failure', () => {
    const summary = summarizeServices([issue('snap'), issue('style')]);
    expect(summary?.text.indexOf("Basemap won't load")).toBeLessThan(
      summary!.text.indexOf("Trails aren't snapping"),
    );
  });

  it('explains a rate limit as self-clearing', () => {
    const summary = summarizeServices([issue('style', { rateLimited: true })]);
    expect(summary?.text).toContain('free plan caps request volume');
  });

  it('mentions a rate limit even when it arrived with another service', () => {
    const summary = summarizeServices([issue('elevation'), issue('search', { rateLimited: true })]);
    expect(summary?.text).toContain('free plan caps request volume');
  });

  it('lists each service once no matter how many times it failed', () => {
    const summary = summarizeServices([issue('basemap'), issue('basemap'), issue('basemap')]);
    expect(summary?.text.match(/basemap tiles/gi)).toHaveLength(1);
  });
});

describe('ServiceStatus', () => {
  const banner = () => document.createElement('div');

  afterEach(() => document.body.replaceChildren());

  it('stays hidden until something fails', () => {
    const element = banner();
    element.className = 'service-banner hidden';
    const status = new ServiceStatus(element);
    expect(status.active).toHaveLength(0);
    expect(element.classList.contains('hidden')).toBe(true);
  });

  it('drops its severity class when it recovers', () => {
    const element = banner();
    const status = new ServiceStatus(element);
    status.report('style', STYLE_ERROR);
    status.resolve('style');
    expect(element.className).toBe('service-banner hidden');
  });

  it('shows the failure and marks a dead style as an error', () => {
    const element = banner();
    const status = new ServiceStatus(element);
    status.report('style', STYLE_ERROR);
    expect(element.classList.contains('hidden')).toBe(false);
    expect(element.className).toContain('service-banner-error');
    expect(element.textContent).toContain("Basemap won't load");
  });

  it('folds repeated failures of one service into a single issue', () => {
    const element = banner();
    const status = new ServiceStatus(element);
    status.report('basemap', TILE_ERROR);
    status.report('basemap', TILE_ERROR);
    status.report('basemap', TILE_ERROR);
    expect(status.active).toHaveLength(1);
    expect(status.active[0].count).toBe(3);
  });

  it('clears a service as soon as it answers again', () => {
    const element = banner();
    const status = new ServiceStatus(element);
    status.report('style', STYLE_ERROR);
    status.report('basemap', TILE_ERROR);
    status.resolve('basemap');
    expect(status.active.map((i) => i.kind)).toEqual(['style']);
    expect(element.classList.contains('hidden')).toBe(false);
    status.resolve('style');
    expect(status.active).toHaveLength(0);
    expect(element.classList.contains('hidden')).toBe(true);
    expect(element.textContent).toBe('');
  });

  it('re-renders when the loudest issue recovers', () => {
    const element = banner();
    const status = new ServiceStatus(element);
    status.report('style', STYLE_ERROR);
    status.report('elevation', DEM_ERROR);
    expect(element.textContent).toContain("Basemap won't load");
    status.resolve('style');
    // Still an error: dead terrain is what leaves the stats and profile blank.
    expect(element.className).toContain('service-banner-error');
    expect(element.textContent).toContain("Terrain won't load");
    expect(element.textContent).not.toContain("Basemap won't load");
  });

  it('keeps a rate-limit note even if a later report of the same service is not one', () => {
    const element = banner();
    const status = new ServiceStatus(element);
    status.report('elevation', DEM_ERROR);
    status.report('elevation', 'network unreachable');
    expect(element.textContent).toContain('free plan caps request volume');
  });

  it('clear() drops everything', () => {
    const element = banner();
    const status = new ServiceStatus(element);
    status.report('style', STYLE_ERROR);
    status.report('search', 'offline');
    status.clear();
    expect(status.active).toHaveLength(0);
    expect(element.classList.contains('hidden')).toBe(true);
  });
});

describe('reportServiceFailure', () => {
  it('notifies subscribers and unsubscribes cleanly', () => {
    const seen: { kind: string; rateLimited: boolean }[] = [];
    const off = onServiceFailure((issue) => seen.push({ kind: issue.kind, rateLimited: issue.rateLimited }));
    reportServiceFailure('elevation', DEM_ERROR);
    reportServiceFailure('search', 'offline');
    off();
    reportServiceFailure('basemap', TILE_ERROR);
    expect(seen).toEqual([
      { kind: 'elevation', rateLimited: true },
      { kind: 'search', rateLimited: false },
    ]);
  });
});
