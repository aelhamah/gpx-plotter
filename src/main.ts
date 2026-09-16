import 'maplibre-gl/dist/maplibre-gl.css';
import maplibregl, { type MapMouseEvent, type Marker } from 'maplibre-gl';
import type { GeoJSONSource } from 'maplibre-gl';
import type { Feature, FeatureCollection, LineString, Point } from 'geojson';
import { DEFAULT_CENTER, DEFAULT_ZOOM, MAP_STYLE_URL, MAPTILER_API_KEY, SATELLITE_STYLE_URL, TERRAIN_URL } from './config';
import { colorToAlpha, haversineMeters, metersToFeet, metersToMiles, nearestProfileSample, profileAxisLabel, profileAxisStep, routeDistanceMeters, routeProfilePoints, segmentSlopeDegrees, summarizeProfile } from './geo';
import { exportGPX, parseGPX, type Route, type RoutePoint } from './gpx';
import { DEM_MAX_ZOOM, elevationAt, slopeBandColorHex, slopeCanvasForTile } from './dem';
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

// Serve color-graded slope raster tiles to MapLibre via a custom protocol, so the
// shading stays perfectly aligned through pan/pitch/rotate (no canvas reprojection).
maplibregl.addProtocol('slope', (async (requestParameters: { url: string }) => {
  try {
    const [z, x, y] = requestParameters.url.replace(/^slope:\/\//, '').split('/').map(Number);
    const canvas = await slopeCanvasForTile(z, x, y);
    if (!canvas) throw new Error('slope tile unavailable');
    const data = await new Promise<ArrayBuffer>((resolve, reject) => {
      canvas.toBlob((blob) => (blob ? blob.arrayBuffer().then(resolve, reject) : reject(new Error('slope tile encode failed'))), 'image/png');
    });
    return { data, contentType: 'image/png' };
  } catch (error) {
    console.error('slope protocol error:', error);
    mapStatus.textContent = `Slope layer error: ${error instanceof Error ? error.message : String(error)}`;
    throw error;
  }
}) as unknown as Parameters<typeof maplibregl.addProtocol>[1]);

map.on('load', () => {
  map.touchZoomRotate.enableRotation();
  addDataLayers();
  updateUI();
});

map.on('style.load', () => {
  addDataLayers();
  updateUI();
});

function addDataLayers() {
  if (!map.getSource('terrain')) {
    map.addSource('terrain', { type: 'raster-dem', url: TERRAIN_URL, tileSize: 512, maxzoom: DEM_MAX_ZOOM });
  }
  if (!map.getSource('slope')) {
    map.addSource('slope', { type: 'raster', tiles: ['slope://{z}/{x}/{y}'], tileSize: 512, maxzoom: DEM_MAX_ZOOM });
  }
  if (!map.getLayer('slope-shading')) {
    map.addLayer({ id: 'slope-shading', type: 'raster', source: 'slope', layout: { visibility: slopeEnabled ? 'visible' : 'none' }, paint: { 'raster-opacity': 0.9, 'raster-fade-duration': 0, 'raster-resampling': 'linear' } });
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
  if (!map.getSource('profile-trace')) {
    map.addSource('profile-trace', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
  }
  if (!map.getLayer('profile-trace')) {
    map.addLayer({ id: 'profile-trace', type: 'line', source: 'profile-trace', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': '#0ea5e9', 'line-width': 7, 'line-opacity': 0.85 } });
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

interface RouteStats { gain?: number; loss?: number; min?: number; max?: number; maxSlope?: number; }
const EMPTY_STATS: RouteStats = {};
let routeStats: RouteStats = EMPTY_STATS;
let statsToken = 0;
const STATS_PROFILE_STEP_METERS = 30;

const statsProgress = $('stats-progress');
function setStatsLoading(loading: boolean) {
  statsProgress.classList.toggle('hidden', !loading);
}

/**
 * Sample the terrain along every route line (~30 m spacing) and recompute
 * gain/loss/low/high/max-slope from that profile, so the numbers reflect the
 * terrain crossed between points rather than just the clicked vertices. Missing
 * elevations are written back into the shared vertex objects on the way, so
 * exported GPX files also carry the filled <ele> values.
 */
async function refreshRouteStats() {
  const token = ++statsToken;
  setStatsLoading(true);
  const profile = routeProfilePoints(route.points, STATS_PROFILE_STEP_METERS);
  const jobs: { point: RoutePoint; promise: Promise<number | undefined> }[] = [];
  for (const point of profile) {
    if (!Number.isFinite(point.elevation)) jobs.push({ point, promise: elevationAt(point.lon, point.lat) });
  }
  const elevations = await Promise.all(jobs.map((j) => j.promise));
  for (let i = 0; i < jobs.length; i++) {
    const elevation = elevations[i];
    if (elevation !== undefined) jobs[i].point.elevation = elevation;
  }
  if (token !== statsToken) return;
  setStatsLoading(false);

  routeProfile = profile;
  routeStats = summarizeProfile(profile);
  updateUI();
  drawProfileChart();
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
        await refreshRouteStats();
        refreshRouteLayer();
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
function undo() { const previous = history.pop(); if (!previous) return; future.push(snapshot()); route = previous; selectedIndex = null; routeName.value = route.name; refreshRouteLayer(); updateUI(); void refreshRouteStats(); }
function redo() { const next = future.pop(); if (!next) return; history.push(snapshot()); route = next; selectedIndex = null; routeName.value = route.name; refreshRouteLayer(); updateUI(); void refreshRouteStats(); }

function startDrawing() { drawing = true; $('draw-route').textContent = 'Drawing…'; $('draw-route').classList.add('active'); $('draw-hint').classList.remove('hidden'); map.getCanvas().style.cursor = 'crosshair'; }
function stopDrawing() { drawing = false; $('draw-route').textContent = 'Draw route'; $('draw-route').classList.remove('active'); $('draw-hint').classList.add('hidden'); map.getCanvas().style.cursor = ''; }

map.on('click', (event: MapMouseEvent) => {
  if (!drawing || rotating || rotatedThisGesture) return;
  commitSnapshot();
  route.points.push({ lat: event.lngLat.lat, lon: event.lngLat.lng });
  selectedIndex = route.points.length - 1;
  refreshRouteLayer();
  updateUI();
  void refreshRouteStats();
});
map.on('dblclick', (event: MapMouseEvent) => {
  if (!drawing) return;
  event.preventDefault();
  if (route.points.length >= 2) {
    const a = route.points[route.points.length - 1], b = route.points[route.points.length - 2];
    if (Math.abs(a.lat - b.lat) < 1e-9 && Math.abs(a.lon - b.lon) < 1e-9) route.points.pop();
  }
  stopDrawing(); refreshRouteLayer(); updateUI(); void refreshRouteStats();
});

window.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && drawing) { stopDrawing(); return; }
  const metaOrCtrl = event.metaKey || event.ctrlKey;
  if (metaOrCtrl && event.key.toLowerCase() === 'z') { event.preventDefault(); event.shiftKey ? redo() : undo(); }
  if (event.key === 'Delete' && selectedIndex !== null) { commitSnapshot(); route.points.splice(selectedIndex, 1); selectedIndex = null; refreshRouteLayer(); updateUI(); void refreshRouteStats(); }
});

// ⌘/Ctrl + click and drag orients the camera like Google Maps:
// drag up/down to tilt (pitch), drag left/right to rotate the bearing.
map.on('mousedown', (event: MapMouseEvent) => {
  const original = event.originalEvent;
  if (original.button !== 0) return;
  if (!(original.metaKey || original.ctrlKey)) {
    rotatedThisGesture = false;
    return;
  }
  original.preventDefault();
  rotating = true;
  rotatedThisGesture = true; // swallow this gesture's own synthetic 'click' (see map 'click')
  map.dragPan.disable();
  const canvas = map.getCanvas();
  const rect = canvas.getBoundingClientRect();
  const startX = event.point.x;
  const startY = event.point.y;
  const startBearing = map.getBearing();
  const startPitch = map.getPitch();
  const rotPerPx = 180 / rect.width;   // full-width drag ≈ 180° of bearing
  const tiltPerPx = 70 / rect.height;  // full-height drag ≈ 70° of pitch
  const clampPitch = (p: number) => (p < 0 ? 0 : p > 85 ? 85 : p);
  map.getCanvas().style.cursor = 'grabbing';
  const move = (e: MouseEvent) => {
    const dx = e.clientX - rect.left - startX;
    const dy = e.clientY - rect.top - startY;
    let bearing = startBearing + dx * rotPerPx;
    bearing = ((bearing % 360) + 540) % 360 - 180; // wrap to [-180, 180]
    const pitch = clampPitch(startPitch - dy * tiltPerPx); // drag up tilts back, drag down tilts down
    map.jumpTo({ bearing, pitch });
  };
  const up = () => {
    rotating = false;
    map.dragPan.enable();
    canvas.style.cursor = '';
    document.removeEventListener('mousemove', move);
    document.removeEventListener('mouseup', up);
  };
  document.addEventListener('mousemove', move);
  document.addEventListener('mouseup', up);
});

$('draw-route').addEventListener('click', () => drawing ? stopDrawing() : startDrawing());
$('undo').addEventListener('click', undo);
$('redo').addEventListener('click', redo);
$('new-route').addEventListener('click', () => { commitSnapshot(); stopDrawing(); route = { name: 'My Route', points: [] }; selectedIndex = null; routeName.value = route.name; routeStats = EMPTY_STATS; setStatsLoading(false); routeProfile = []; refreshRouteLayer(); updateUI(); drawProfileChart(); });
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
  if (map.getLayer('slope-shading')) map.setLayoutProperty('slope-shading', 'visibility', slopeEnabled ? 'visible' : 'none');
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
    const content = await file.text();
    const doc = new DOMParser().parseFromString(content, 'application/xml');
    const imported = parseGPX(content);
    if (doc.documentElement.getAttribute('creator') === 'GPX Plotter') {
      // Files we exported carry DEM-sampled elevations; they may be stale, so ignore them and re-query the terrain.
      imported.points = imported.points.map(({ lat, lon }) => ({ lat, lon }));
    }
    commitSnapshot(); route = imported; selectedIndex = null; routeName.value = route.name;
    refreshRouteLayer(); updateUI(); fitRoute();
    await refreshRouteStats();
    refreshRouteLayer();
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

function formatElevation(meters: number | undefined) { return meters === undefined ? '—' : `${Math.round(metersToFeet(meters)).toLocaleString()} ft`; }
function updateUI() {
  const distance = routeDistanceMeters(route.points);
  $('distance').textContent = route.points.length >= 2 ? `${metersToMiles(distance).toFixed(2)} mi` : '—';
  $('gain').textContent = formatElevation(routeStats.gain);
  $('loss').textContent = formatElevation(routeStats.loss);
  $('min-elevation').textContent = formatElevation(routeStats.min);
  $('max-elevation').textContent = formatElevation(routeStats.max);
  $('point-count').textContent = String(route.points.length);
  $('max-slope').textContent = routeStats.maxSlope === undefined ? '—' : `${Math.round(routeStats.maxSlope)}°`;
  $('slope-note').textContent = routeStats.gain === undefined
    ? 'Terrain stats will appear as the route grows'
    : 'Gain/loss/low/high follow the terrain along the route';
}

// --- Elevation profile chart -------------------------------------------------
const PROFILE_PAD_L = 38;
const PROFILE_PAD_R = 10;
const PROFILE_PAD_T = 10;
const PROFILE_PAD_B = 20;

/** Resampled terrain along the route; the same data that drives gain/loss stats. */
let routeProfile: RoutePoint[] = [];
let profileHoverIndex: number | null = null;
let profileHoverMarker: Marker | null = null;

const profileCanvas = $('profile') as HTMLCanvasElement;
const profileReadout = $('profile-readout');
const profileEmpty = $('profile-empty');

function clearProfileHover() {
  profileHoverIndex = null;
  profileHoverMarker?.remove();
  profileHoverMarker = null;
  updateProfileTrace(null);
}

function updateProfileTrace(hoverIndex: number | null) {
  const source = map.getSource('profile-trace') as GeoJSONSource | undefined;
  if (!source) return;
  const features: Feature<LineString>[] = [];
  if (hoverIndex !== null && hoverIndex >= 0) {
    const coordinates = routeProfile.slice(0, hoverIndex + 1).map((p) => [p.lon, p.lat] as [number, number]);
    if (coordinates.length >= 2) features.push({ type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates } });
  }
  source.setData({ type: 'FeatureCollection', features });
}

interface ProfileGeometry {
  cumulative: number[];
  validSamples: number[];
  total: number;
  yMin: number;
  yMax: number;
}

function profileData(): ProfileGeometry | null {
  const n = routeProfile.length;
  if (n < 2) return null;
  const cumulative = new Array<number>(n);
  let cum = 0;
  for (let i = 0; i < n; i++) {
    if (i > 0) cum += haversineMeters(routeProfile[i - 1], routeProfile[i]);
    cumulative[i] = cum;
  }
  const validSamples: number[] = [];
  let min = Infinity;
  let max = -Infinity;
  for (let i = 0; i < n; i++) {
    const elevation = routeProfile[i].elevation;
    if (Number.isFinite(elevation)) {
      validSamples.push(i);
      if ((elevation as number) < min) min = elevation as number;
      if ((elevation as number) > max) max = elevation as number;
    }
  }
  if (validSamples.length < 2 || !Number.isFinite(min) || !Number.isFinite(max)) return null;
  const range = (max - min) || 1;
  return {
    cumulative,
    validSamples,
    total: cum,
    yMin: min - range * 0.08,
    yMax: max + range * 0.08,
  };
}

function profilePlotGeometry(): (ProfileGeometry & { plotW: number; plotH: number }) | null {
  const data = profileData();
  if (!data || profileCanvas.clientWidth === 0) return null;
  return {
    ...data,
    plotW: Math.max(profileCanvas.clientWidth - PROFILE_PAD_L - PROFILE_PAD_R, 2),
    plotH: Math.max(profileCanvas.clientHeight - PROFILE_PAD_T - PROFILE_PAD_B, 2),
  };
}

function drawProfileChart() {
  const data = profileData();
  profileCanvas.classList.toggle('hidden', !data);
  profileEmpty.classList.toggle('hidden', !!data);
  if (!data) {
    profileReadout.classList.add('hidden');
    clearProfileHover();
    return;
  }
  const geometry = profilePlotGeometry();
  if (!geometry) return;
  const cssWidth = profileCanvas.clientWidth;
  const cssHeight = profileCanvas.clientHeight;
  const dpr = window.devicePixelRatio || 1;
  if (profileCanvas.width !== Math.round(cssWidth * dpr)) profileCanvas.width = Math.round(cssWidth * dpr);
  if (profileCanvas.height !== Math.round(cssHeight * dpr)) profileCanvas.height = Math.round(cssHeight * dpr);
  const context = profileCanvas.getContext('2d');
  if (!context) return;
  context.setTransform(dpr, 0, 0, dpr, 0, 0);
  context.clearRect(0, 0, cssWidth, cssHeight);

  const xAt = (cumulative: number) => PROFILE_PAD_L + (cumulative / geometry.total) * geometry.plotW;
  const yAt = (elevation: number) => PROFILE_PAD_T + (1 - (elevation - geometry.yMin) / (geometry.yMax - geometry.yMin)) * geometry.plotH;

  context.font = '10px Inter, ui-sans-serif, system-ui, sans-serif';
  context.fillStyle = '#94a3b8';
  context.strokeStyle = '#e2e8f0';
  context.lineWidth = 1;
  const gridCount = 3;
  for (let g = 0; g <= gridCount; g++) {
    const value = geometry.yMin + ((geometry.yMax - geometry.yMin) * g) / gridCount;
    const y = yAt(value);
    context.beginPath();
    context.moveTo(PROFILE_PAD_L, y);
    context.lineTo(cssWidth - PROFILE_PAD_R, y);
    context.stroke();
    context.fillText(`${Math.round(metersToFeet(value)).toLocaleString()}`, 2, y + 3);
  }

  const axisStep = profileAxisStep(geometry.total);
  if (axisStep > 0) {
    const ticks: number[] = [];
    for (let d = axisStep; d < geometry.total - 1e-6; d += axisStep) ticks.push(d);
    for (const t of ticks) {
      const x = xAt(t);
      context.strokeStyle = '#f1f5f9';
      context.beginPath();
      context.moveTo(x, PROFILE_PAD_T);
      context.lineTo(x, cssHeight - PROFILE_PAD_B);
      context.stroke();
      const label = t === ticks[ticks.length - 1] ? `${profileAxisLabel(t)} mi` : profileAxisLabel(t);
      context.fillStyle = '#94a3b8';
      context.fillText(label, x - context.measureText(label).width / 2, cssHeight - 6);
    }
    context.fillText('0', PROFILE_PAD_L - context.measureText('0').width / 2, cssHeight - 6);
  }

const baseY = cssHeight - PROFILE_PAD_B;
  context.lineJoin = 'round';
  context.lineCap = 'round';

  const profilePolyline = new Path2D();
  let first = true;
  for (const i of geometry.validSamples) {
    const x = xAt(geometry.cumulative[i]);
    const y = yAt(routeProfile[i].elevation as number);
    if (first) {
      profilePolyline.moveTo(x, y);
      first = false;
    } else {
      profilePolyline.lineTo(x, y);
    }
  }
  context.strokeStyle = '#f8fafc';
  context.lineWidth = 6;
  context.stroke(profilePolyline);

  for (let s = 0; s < geometry.validSamples.length - 1; s++) {
    const a = geometry.validSamples[s];
    const b = geometry.validSamples[s + 1];
    const slope = segmentSlopeDegrees(routeProfile[a], routeProfile[b]);
    const color = slope === undefined ? '#94a3b8' : slopeBandColorHex(slope);
    const x0 = xAt(geometry.cumulative[a]);
    const y0 = yAt(routeProfile[a].elevation as number);
    const x1 = xAt(geometry.cumulative[b]);
    const y1 = yAt(routeProfile[b].elevation as number);

    context.fillStyle = colorToAlpha(color, 0.22);
    context.beginPath();
    context.moveTo(x0, y0);
    context.lineTo(x1, y1);
    context.lineTo(x1, baseY);
    context.lineTo(x0, baseY);
    context.closePath();
    context.fill();

    context.strokeStyle = color;
    context.lineWidth = 3;
    context.beginPath();
    context.moveTo(x0, y0);
    context.lineTo(x1, y1);
    context.stroke();
  }

  if (profileHoverIndex !== null && geometry.validSamples.includes(profileHoverIndex)) {
    const x = xAt(geometry.cumulative[profileHoverIndex]);
    const y = yAt(routeProfile[profileHoverIndex].elevation as number);
    context.setLineDash([3, 3]);
    context.strokeStyle = 'rgba(15,23,42,.45)';
    context.beginPath();
    context.moveTo(x, PROFILE_PAD_T);
    context.lineTo(x, baseY);
    context.stroke();
    context.setLineDash([]);
    context.fillStyle = '#fff';
    context.beginPath();
    context.arc(x, y, 5, 0, Math.PI * 2);
    context.fill();
    context.strokeStyle = '#111827';
    context.lineWidth = 2;
    context.stroke();
    context.setLineDash([]);
    context.fillStyle = '#fff';
    context.beginPath();
    context.arc(x, y, 5, 0, Math.PI * 2);
    context.fill();
    context.strokeStyle = '#e11d48';
    context.stroke();
  }
}

function profileSampleAt(geometry: ProfileGeometry & { plotW: number; plotH: number }, mouseX: number): number | null {
  const target = ((mouseX - PROFILE_PAD_L) / geometry.plotW) * geometry.total;
  const cumulative = geometry.validSamples.map((i) => geometry.cumulative[i]);
  return geometry.validSamples[nearestProfileSample(cumulative, target)];
}

profileCanvas.addEventListener('pointermove', (event) => {
  const rect = profileCanvas.getBoundingClientRect();
  const geometry = profilePlotGeometry();
  if (!geometry) return;
  const index = profileSampleAt(geometry, event.clientX - rect.left);
  if (index === null) return;
  profileHoverIndex = index;
  const point = routeProfile[index];
  profileReadout.textContent = `${metersToMiles(geometry.cumulative[index]).toFixed(2)} mi · ${formatElevation(point.elevation)}`;
  profileReadout.classList.remove('hidden');
  if (!profileHoverMarker) {
    const element = document.createElement('div');
    element.className = 'profile-hover-marker';
    profileHoverMarker = new maplibregl.Marker({ element, anchor: 'center' });
    profileHoverMarker.setLngLat([point.lon, point.lat]).addTo(map);
  } else {
    profileHoverMarker.setLngLat([point.lon, point.lat]);
  }
  updateProfileTrace(index);
  drawProfileChart();
});
profileCanvas.addEventListener('pointerleave', () => {
  clearProfileHover();
  profileReadout.classList.add('hidden');
  drawProfileChart();
});
window.addEventListener('resize', () => drawProfileChart());