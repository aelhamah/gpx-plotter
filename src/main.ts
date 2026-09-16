import 'maplibre-gl/dist/maplibre-gl.css';
import maplibregl, { type MapMouseEvent, type Marker } from 'maplibre-gl';
import type { GeoJSONSource } from 'maplibre-gl';
import type { Feature, FeatureCollection, LineString, Point } from 'geojson';
import { DEFAULT_CENTER, DEFAULT_ZOOM, MAP_STYLE_URL, MAPTILER_API_KEY, SATELLITE_STYLE_URL, TERRAIN_URL } from './config';
import { elevationStats, metersToFeet, metersToMiles, routeDistanceMeters, segmentSlopeDegrees } from './geo';
import { exportGPX, parseGPX, type Route, type RoutePoint } from './gpx';
import { DEM_MAX_ZOOM, elevationAt, lngLatToTile, slopeCanvasForTile, tileNWLngLat, worldMercator } from './dem';
import './style.css';

const emptyRoute: Route = { name: 'My Route', points: [] };
let route: Route = structuredClone(emptyRoute);
let drawing = false;
let terrainEnabled = false;
let reliefEnabled = false;
let satelliteEnabled = false;
let slopeEnabled = false;
let selectedIndex: number | null = null;
let markers: Marker[] = [];
let rotating = false;
let rotatedThisGesture = false;
const history: Route[] = [];
const future: Route[] = [];

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const mapStatus = $('map-status');
const routeName = $('route-name') as HTMLInputElement;
const slopeOverlay = $('slope-overlay') as HTMLCanvasElement;

if (!MAPTILER_API_KEY) {
  mapStatus.textContent = 'MapTiler key missing — add it in src/config.ts, then reload.';
}

const map = new maplibregl.Map({
  container: 'map',
  style: MAP_STYLE_URL,
  center: DEFAULT_CENTER,
  zoom: DEFAULT_ZOOM,
  maxPitch: 85,
  attributionControl: false,
  dragRotate: false,
  touchZoomRotate: true,
});

map.addControl(new maplibregl.NavigationControl({ visualizePitch: true }), 'top-right');
map.addControl(new maplibregl.AttributionControl(), 'bottom-right');

map.on('load', () => {
  map.touchZoomRotate.enableRotation();
  addDataLayers();
  updateUI();
});

map.on('style.load', () => {
  addDataLayers();
  updateUI();
});

map.on('idle', () => {
  if (slopeEnabled) renderSlopeOverlay();
});

function addDataLayers() {
  if (!map.getSource('terrain')) {
    map.addSource('terrain', { type: 'raster-dem', url: TERRAIN_URL, tileSize: 512, maxzoom: DEM_MAX_ZOOM });
  }
  if (!map.getSource('route')) {
    map.addSource('route', { type: 'geojson', data: routeGeoJSON() });
  }
  if (!map.getLayer('route-casing')) {
    map.addLayer({ id: 'route-casing', type: 'line', source: 'route', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': '#ffffff', 'line-width': 8, 'line-opacity': 0.88 } });
  }
  if (!map.getLayer('route-line')) {
    map.addLayer({ id: 'route-line', type: 'line', source: 'route', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': '#e11d48', 'line-width': 4 } });
  }
  if (!map.getLayer('relief')) {
    map.addLayer({ id: 'relief', type: 'hillshade', source: 'terrain', layout: { visibility: reliefEnabled ? 'visible' : 'none' }, paint: { 'hillshade-shadow-color': '#334155', 'hillshade-highlight-color': '#ffffff', 'hillshade-accent-color': '#64748b', 'hillshade-exaggeration': 0.5 } });
  }
  refreshMarkers();
}

function routeGeoJSON(): FeatureCollection<LineString | Point> {
  const line: Feature<LineString> = { type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: route.points.map((p) => [p.lon, p.lat]) } };
  return { type: 'FeatureCollection', features: route.points.length >= 2 ? [line] : [] };
}

function refreshRouteLayer() {
  const source = map.getSource('route') as GeoJSONSource | undefined;
  if (source) source.setData(routeGeoJSON());
  refreshMarkers();
}

/**
 * Query the MapTiler DEM for any route points that are missing elevation,
 * so gain/loss/low/high and max slope always populate. Preserves elevations
 * that came from an imported GPX.
 */
async function fillElevations(indices?: number[]): Promise<void> {
  const targets = (indices ?? route.points.map((_, i) => i)).filter((i) => !Number.isFinite(route.points[i].elevation));
  const results = await Promise.all(targets.map(async (i) => {
    const point = route.points[i];
    const elevation = await elevationAt(point.lon, point.lat);
    const current = route.points[i];
    if (elevation !== undefined && current.lat === point.lat && current.lon === point.lon && !Number.isFinite(current.elevation)) {
      route.points[i] = { ...current, elevation };
    }
  }));
  void results;
}

function refreshMarkers() {
  for (const marker of markers) marker.remove();
  markers = [];
  route.points.forEach((point, index) => {
    const el = document.createElement('button');
    el.className = `route-marker ${selectedIndex === index ? 'selected' : ''}`;
    el.type = 'button';
    el.title = `Point ${index + 1}`;
    el.addEventListener('click', (event) => { event.stopPropagation(); selectedIndex = index; refreshMarkers(); });
    el.addEventListener('pointerdown', (event) => {
      event.stopPropagation();
      if (event.button !== 0) return;
      selectedIndex = index;
      map.dragPan.disable();
      const move = (e: PointerEvent) => {
        const rect = map.getCanvas().getBoundingClientRect();
        const lngLat = map.unproject([e.clientX - rect.left, e.clientY - rect.top]);
        route.points[index] = { lat: lngLat.lat, lon: lngLat.lng };
        refreshRouteLayer();
        updateUI();
      };
      const up = async () => {
        document.removeEventListener('pointermove', move);
        document.removeEventListener('pointerup', up);
        map.dragPan.enable();
        await fillElevations([index]);
        refreshRouteLayer();
        updateUI();
        commitSnapshot();
      };
      document.addEventListener('pointermove', move);
      document.addEventListener('pointerup', up, { once: true });
    });
    markers.push(new maplibregl.Marker({ element: el, anchor: 'center' }).setLngLat([point.lon, point.lat]).addTo(map));
  });
}

function snapshot() { return structuredClone(route); }
function commitSnapshot() { history.push(snapshot()); if (history.length > 50) history.shift(); future.length = 0; }
function undo() { const previous = history.pop(); if (!previous) return; future.push(snapshot()); route = previous; selectedIndex = null; routeName.value = route.name; refreshRouteLayer(); updateUI(); }
function redo() { const next = future.pop(); if (!next) return; history.push(snapshot()); route = next; selectedIndex = null; routeName.value = route.name; refreshRouteLayer(); updateUI(); }

function startDrawing() { drawing = true; $('draw-route').textContent = 'Drawing…'; $('draw-route').classList.add('active'); $('draw-hint').classList.remove('hidden'); map.getCanvas().style.cursor = 'crosshair'; }
function stopDrawing() { drawing = false; $('draw-route').textContent = 'Draw route'; $('draw-route').classList.remove('active'); $('draw-hint').classList.add('hidden'); map.getCanvas().style.cursor = ''; }

map.on('click', (event: MapMouseEvent) => {
  if (!drawing || rotating || rotatedThisGesture) return;
  commitSnapshot();
  route.points.push({ lat: event.lngLat.lat, lon: event.lngLat.lng });
  selectedIndex = route.points.length - 1;
  refreshRouteLayer();
  updateUI();
  fillElevations([route.points.length - 1]).then(() => { refreshRouteLayer(); updateUI(); });
});
map.on('dblclick', (event: MapMouseEvent) => {
  if (!drawing) return;
  event.preventDefault();
  if (route.points.length >= 2) {
    const a = route.points[route.points.length - 1], b = route.points[route.points.length - 2];
    if (Math.abs(a.lat - b.lat) < 1e-9 && Math.abs(a.lon - b.lon) < 1e-9) route.points.pop();
  }
  stopDrawing(); refreshRouteLayer(); updateUI();
});

window.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && drawing) { stopDrawing(); return; }
  const metaOrCtrl = event.metaKey || event.ctrlKey;
  if (metaOrCtrl && event.key.toLowerCase() === 'z') { event.preventDefault(); event.shiftKey ? redo() : undo(); }
  if (event.key === 'Delete' && selectedIndex !== null) { commitSnapshot(); route.points.splice(selectedIndex, 1); selectedIndex = null; refreshRouteLayer(); updateUI(); }
});

// ⌘/Ctrl + click and drag rotates the camera bearing.
map.on('mousedown', (event: MapMouseEvent) => {
  const original = event.originalEvent;
  if (original.button !== 0) return;
  if (!(original.metaKey || original.ctrlKey)) return;
  original.preventDefault();
  rotating = true;
  rotatedThisGesture = false;
  map.dragPan.disable();
  const canvas = map.getCanvas();
  const startAngle = Math.atan2(event.point.y - canvas.clientHeight / 2, event.point.x - canvas.clientWidth / 2);
  const startBearing = map.getBearing();
  map.getCanvas().style.cursor = 'grabbing';
  const move = (e: MouseEvent) => {
    const rect = canvas.getBoundingClientRect();
    const angle = Math.atan2(e.clientY - rect.top - rect.height / 2, e.clientX - rect.left - rect.width / 2);
    let delta = (angle - startAngle) * (180 / Math.PI);
    delta = ((delta % 360) + 540) % 360 - 180; // wrap to [-180, 180]
    map.jumpTo({ bearing: startBearing + delta });
    if (Math.abs(angle - startAngle) > 0.01) rotatedThisGesture = true;
  };
  const up = () => {
    rotating = false;
    map.dragPan.enable();
    canvas.style.cursor = '';
    document.removeEventListener('mousemove', move);
    document.removeEventListener('mouseup', up);
    if (slopeEnabled) renderSlopeOverlay();
  };
  document.addEventListener('mousemove', move);
  document.addEventListener('mouseup', up);
});

$('draw-route').addEventListener('click', () => drawing ? stopDrawing() : startDrawing());
$('undo').addEventListener('click', undo);
$('redo').addEventListener('click', redo);
$('new-route').addEventListener('click', () => { commitSnapshot(); stopDrawing(); route = { name: 'My Route', points: [] }; selectedIndex = null; routeName.value = route.name; refreshRouteLayer(); updateUI(); });
routeName.addEventListener('input', () => { route.name = routeName.value || 'My Route'; });
$('fit-route').addEventListener('click', fitRoute);

$('terrain-toggle').addEventListener('click', () => {
  terrainEnabled = !terrainEnabled;
  if (terrainEnabled) { map.setTerrain({ source: 'terrain', exaggeration: 1.15 }); map.easeTo({ pitch: 55, duration: 600 }); }
  else { map.setTerrain(null); map.easeTo({ pitch: 0, duration: 600 }); }
  $('terrain-toggle').classList.toggle('active', terrainEnabled);
});

$('relief-toggle').addEventListener('click', () => {
  reliefEnabled = !reliefEnabled;
  if (map.getLayer('relief')) map.setLayoutProperty('relief', 'visibility', reliefEnabled ? 'visible' : 'none');
  $('relief-toggle').classList.toggle('active', reliefEnabled);
});

$('slope-toggle').addEventListener('click', () => {
  slopeEnabled = !slopeEnabled;
  $('slope-toggle').classList.toggle('active', slopeEnabled);
  $('slope-legend').classList.toggle('hidden', !slopeEnabled);
  if (slopeEnabled) renderSlopeOverlay();
  else slopeOverlay.classList.add('hidden');
});

$('imagery-toggle').addEventListener('click', () => {
  satelliteEnabled = !satelliteEnabled;
  const center = map.getCenter(); const zoom = map.getZoom(); const bearing = map.getBearing(); const pitch = map.getPitch();
  map.setStyle(satelliteEnabled ? SATELLITE_STYLE_URL : MAP_STYLE_URL);
  map.once('style.load', () => map.jumpTo({ center, zoom, bearing, pitch }));
  $('imagery-toggle').classList.toggle('active', satelliteEnabled);
});

$('gpx-input').addEventListener('change', async (event) => {
  const input = event.target as HTMLInputElement; const file = input.files?.[0]; if (!file) return;
  try {
    const imported = parseGPX(await file.text());
    commitSnapshot(); route = imported; selectedIndex = null; routeName.value = route.name;
    refreshRouteLayer(); updateUI(); fitRoute();
    await fillElevations();
    refreshRouteLayer(); updateUI();
  } catch (error) { alert(error instanceof Error ? error.message : 'Unable to import GPX.'); }
  finally { input.value = ''; }
});

$('export-gpx').addEventListener('click', () => {
  if (route.points.length < 2) { alert('Add at least two points before exporting.'); return; }
  const blob = new Blob([exportGPX(route)], { type: 'application/gpx+xml;charset=utf-8' });
  const url = URL.createObjectURL(blob); const anchor = document.createElement('a'); anchor.href = url;
  anchor.download = `${(route.name || 'route').replace(/[^a-z0-9-_]+/gi, '-').replace(/^-|-$/g, '') || 'route'}.gpx`;
  anchor.click(); URL.revokeObjectURL(url);
});

function fitRoute() {
  if (!route.points.length) return;
  const bounds = new maplibregl.LngLatBounds();
  for (const point of route.points) bounds.extend([point.lon, point.lat]);
  map.fitBounds(bounds, { padding: 80, duration: 700, maxZoom: 15 });
}

let slopeToken = 0;

/** Shade the visible terrain by slope angle using DEM tiles. */
async function renderSlopeOverlay() {
  if (!slopeEnabled || !map.loaded()) return;
  const token = ++slopeToken;
  const zoom = map.getZoom();
  let renderZ = clamp(Math.round(zoom + 1), 9, DEM_MAX_ZOOM);

  const canvas = map.getCanvas();
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  const corners = [
    map.unproject([0, 0]),
    map.unproject([width, 0]),
    map.unproject([0, height]),
    map.unproject([width, height]),
  ];
  const lngs = corners.map((c) => c.lng);
  const lats = corners.map((c) => c.lat);

  let t0 = lngLatToTile(Math.min(...lngs), Math.max(...lats), renderZ);
  let t1 = lngLatToTile(Math.max(...lngs), Math.min(...lats), renderZ);
  let x0 = Math.floor(t0.x) - 1, x1 = Math.floor(t1.x) + 1;
  let y0 = Math.floor(t0.y) - 1, y1 = Math.floor(t1.y) + 1;
  while ((x1 - x0 + 1) * (y1 - y0 + 1) > 256 && renderZ > 9) {
    renderZ -= 1;
    t0 = lngLatToTile(Math.min(...lngs), Math.max(...lats), renderZ);
    t1 = lngLatToTile(Math.max(...lngs), Math.min(...lats), renderZ);
    x0 = Math.floor(t0.x) - 1; x1 = Math.floor(t1.x) + 1;
    y0 = Math.floor(t0.y) - 1; y1 = Math.floor(t1.y) + 1;
  }
  if ((x1 - x0 + 1) * (y1 - y0 + 1) > 256) return;

  const canvases = new Map<string, HTMLCanvasElement>();
  const jobs: Promise<void>[] = [];
  for (let x = x0; x <= x1; x++) {
    for (let y = y0; y <= y1; y++) {
      const key = `${renderZ}/${x}/${y}`;
      jobs.push(slopeCanvasForTile(renderZ, x, y).then((tile) => { if (tile) canvases.set(key, tile); }).catch(() => undefined));
    }
  }
  await Promise.all(jobs);
  if (token !== slopeToken) return;
  slopeOverlay.classList.remove('hidden');
  drawSlopeOverlay(canvases, renderZ, zoom);
}

function drawSlopeOverlay(canvases: Map<string, HTMLCanvasElement>, renderZ: number, mapZoom: number) {
  const context = slopeOverlay.getContext('2d');
  if (!context) return;
  const dpr = window.devicePixelRatio || 1;
  const width = map.getCanvas().clientWidth;
  const height = map.getCanvas().clientHeight;
  const targetWidth = Math.round(width * dpr);
  const targetHeight = Math.round(height * dpr);
  if (slopeOverlay.width !== targetWidth) slopeOverlay.width = targetWidth;
  if (slopeOverlay.height !== targetHeight) slopeOverlay.height = targetHeight;
  context.setTransform(dpr, 0, 0, dpr, 0, 0);
  context.clearRect(0, 0, width, height);

  const bearing = map.getBearing();
  const pitch = map.getPitch();
  const center = map.getCenter();
  const centerWorld = worldMercator(center.lng, center.lat, mapZoom);
  const tileSize = 512 * Math.pow(2, mapZoom - renderZ);

  context.save();
  context.translate(width / 2, height / 2);
  context.rotate((-bearing * Math.PI) / 180);
  context.scale(1, Math.cos((pitch * Math.PI) / 180));
  context.translate(-centerWorld.x, -centerWorld.y);

  canvases.forEach((canvas, key) => {
    const [z, x, y] = key.split('/').map(Number);
    const nw = tileNWLngLat(x, y, z);
    const world = worldMercator(nw.lng, nw.lat, mapZoom);
    context.drawImage(canvas, world.x, world.y, tileSize, tileSize);
  });
  context.restore();
}

function formatElevation(meters: number | undefined) { return meters === undefined ? '—' : `${Math.round(metersToFeet(meters)).toLocaleString()} ft`; }
function updateUI() {
  const distance = routeDistanceMeters(route.points); const stats = elevationStats(route.points);
  $('distance').textContent = route.points.length >= 2 ? `${metersToMiles(distance).toFixed(2)} mi` : '—';
  $('gain').textContent = formatElevation(stats.gain); $('loss').textContent = formatElevation(stats.loss);
  $('min-elevation').textContent = formatElevation(stats.min); $('max-elevation').textContent = formatElevation(stats.max);
  $('point-count').textContent = String(route.points.length);
  const slopeValues = route.points.slice(1).map((p, i) => segmentSlopeDegrees(route.points[i], p)).filter((v): v is number => v !== undefined);
  $('max-slope').textContent = slopeValues.length ? `${Math.round(Math.max(...slopeValues))}°` : '—';
  $('slope-note').textContent = slopeValues.length
    ? 'Maximum route segment angle (DEM-filled elevation)'
    : route.points.some((p) => Number.isFinite(p.elevation))
      ? 'Add a second point to measure slope'
      : 'Elevation will be queried from the terrain DEM';
}

function clamp(value: number, min: number, max: number) {
  return value < min ? min : value > max ? max : value;
}