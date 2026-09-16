import 'maplibre-gl/dist/maplibre-gl.css';
import maplibregl, { type MapMouseEvent, type Marker } from 'maplibre-gl';
import type { GeoJSONSource } from 'maplibre-gl';
import type { Feature, FeatureCollection, LineString, Point } from 'geojson';
import { DEFAULT_CENTER, DEFAULT_ZOOM, MAP_STYLE_URL, MAPTILER_API_KEY, SATELLITE_STYLE_URL, TERRAIN_URL } from './config';
import { colorToAlpha, haversineMeters, nearestProfileSample, profileAxisStep, routeDistanceMeters, routeProfilePoints, segmentSlopeDegrees, summarizeProfile, type UnitSystem } from './geo';
import { exportGPX, parseGPX, type Route, type RoutePoint, type Waypoint } from './gpx';
import { DEM_MAX_ZOOM, elevationAt, slopeBandColorHex, slopeCanvasForTile } from './dem';
import { defaultUnitSystem, formatDistance, formatDistanceAxis, formatElevation, formatSlope } from './units';
import { routeColorForId, TRACE_COLOR } from './colors';
import { normalizeRouteName, normalizeWaypointName } from './names';
import './style.css';

let routes: Route[] = [];
let waypoints: Waypoint[] = [];
let selectedRouteId: number | null = null;
let nextRouteId = 1;
let drawing = false;
let waypointMode = false;
let terrainEnabled = false;
let reliefEnabled = false;
let satelliteEnabled = false;
let slopeEnabled = false;
let unitSystem: UnitSystem = defaultUnitSystem();
let selectedIndex: number | null = null;
let selectedWaypointIndex: number | null = null;
let markers: Marker[] = [];
let waypointMarkerElements: HTMLElement[] = [];
let waypointMarkerLabels: HTMLElement[] = [];
let waypointNameInputs: HTMLInputElement[] = [];
let routeNameWidgets: { label: HTMLElement; text: HTMLElement; input: HTMLInputElement }[] = [];
let rotating = false;
let rotatedThisGesture = false;
interface AppState { routes: Route[]; waypoints: Waypoint[]; }
const history: AppState[] = [];
const future: AppState[] = [];

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const mapStatus = $('map-status');
const routeName = $('route-name') as HTMLInputElement;
const routesList = $('routes-list');
const routesEmpty = $('routes-empty');
const drawHint = $('draw-hint');

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
  applyTerrain();
  updateUI();
});

function applyTerrain() {
  map.setTerrain(terrainEnabled ? { source: 'terrain', exaggeration: 1.15 } : null);
}

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
  if (!map.getSource('routes')) {
    map.addSource('routes', { type: 'geojson', data: routesGeoJSON() });
  }
  if (!map.getLayer('route-casing')) {
    map.addLayer({ id: 'route-casing', type: 'line', source: 'routes', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': '#ffffff', 'line-width': 8, 'line-opacity': 0.88 } });
  }
  if (!map.getLayer('route-line')) {
    map.addLayer({ id: 'route-line', type: 'line', source: 'routes', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': ['coalesce', ['get', 'color'], '#e11d48'], 'line-width': 4 } });
  }
  if (!map.getSource('profile-trace')) {
    map.addSource('profile-trace', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
  }
  if (!map.getLayer('profile-trace')) {
    map.addLayer({ id: 'profile-trace', type: 'line', source: 'profile-trace', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': TRACE_COLOR, 'line-width': 7, 'line-opacity': 0.85 } });
  }
  if (!map.getLayer('relief')) {
    map.addLayer({ id: 'relief', type: 'hillshade', source: 'terrain', layout: { visibility: reliefEnabled ? 'visible' : 'none' }, paint: { 'hillshade-shadow-color': '#334155', 'hillshade-highlight-color': '#ffffff', 'hillshade-accent-color': '#64748b', 'hillshade-exaggeration': 0.5 } });
  }
  refreshMarkers();
}

function routesGeoJSON(): FeatureCollection<LineString | Point> {
  const features: Feature<LineString>[] = routes
    .filter((route) => route.points.length >= 2)
    .map((route) => ({
      type: 'Feature',
      properties: { color: route.color },
      geometry: { type: 'LineString', coordinates: route.points.map((p) => [p.lon, p.lat]) },
    }));
  return { type: 'FeatureCollection', features };
}

function refreshRoutesLayer() {
  const source = map.getSource('routes') as GeoJSONSource | undefined;
  if (source) source.setData(routesGeoJSON());
  fillRouteList();
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

function activeRoute(): Route | null {
  return routes.find((route) => route.id === selectedRouteId) ?? null;
}

/**
 * Sample the terrain along a route (~30 m spacing) and recompute
 * gain/loss/low/high/max-slope from that profile, so the numbers reflect the
 * terrain crossed between points rather than just the clicked vertices.
 */
async function refreshRouteStats() {
  const route = activeRoute();
  if (!route) {
    routeStats = EMPTY_STATS;
    routeProfile = [];
    setStatsLoading(false);
    updateUI();
    drawProfileChart();
    return;
  }
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
  waypointMarkerElements = [];
  waypointMarkerLabels = [];
  waypointNameInputs = [];
  routeNameWidgets = [];
  const route = activeRoute();
  if (route) {
    route.points.forEach((point, index) => {
      const el = document.createElement('button');
      el.className = `route-marker ${selectedIndex === index ? 'selected' : ''}`;
      el.type = 'button';
      el.style.background = route.color;
      el.title = `Point ${index + 1}`;
      el.addEventListener('click', (event) => { event.stopPropagation(); selectedIndex = index; selectedWaypointIndex = null; refreshMarkers(); updateUI(); });
      el.addEventListener('pointerdown', (event) => {
        event.stopPropagation();
        if (event.button !== 0) return;
        selectedIndex = index;
        selectedWaypointIndex = null;
        map.dragPan.disable();
        const move = (e: PointerEvent) => {
          const rect = map.getCanvas().getBoundingClientRect();
          const lngLat = map.unproject([e.clientX - rect.left, e.clientY - rect.top]);
          route.points[index] = { lat: lngLat.lat, lon: lngLat.lng };
          refreshRoutesLayer();
          updateUI();
        };
        const up = async () => {
          document.removeEventListener('pointermove', move);
          document.removeEventListener('pointerup', up);
          map.dragPan.enable();
          await refreshRouteStats();
          refreshRoutesLayer();
          commitSnapshot();
        };
        document.addEventListener('pointermove', move);
        document.addEventListener('pointerup', up, { once: true });
      });
      markers.push(new maplibregl.Marker({ element: el, anchor: 'center' }).setLngLat([point.lon, point.lat]).addTo(map));
    });
  }
  routes.forEach((route, index) => {
    if (!route.points.length) return;
    const mid = route.points[Math.floor(route.points.length / 2)];
    const label = document.createElement('div');
    label.className = `route-map-label ${route.id === selectedRouteId ? 'editable' : ''}`;
    label.style.setProperty('--route-color', route.color);
    label.title = route.name;
    const text = document.createElement('span');
    text.className = 'route-name-text';
    text.textContent = route.name;
    const renameInput = document.createElement('input');
    renameInput.type = 'text';
    renameInput.className = 'route-name-input';
    renameInput.classList.add('hidden');
    renameInput.value = route.name;
    renameInput.spellcheck = false;
    renameInput.addEventListener('keydown', (event) => {
      event.stopPropagation();
      if (event.key === 'Enter' || event.key === 'Escape') renameInput.blur();
    });
    renameInput.addEventListener('input', () => {
      sizeRenameInput(renameInput, renameInput.value);
      if (index < 0 || index >= routes.length) return;
      const name = renameInput.value;
      routes[index].name = name;
      text.textContent = name;
      label.title = name;
      if (routes[index].id === selectedRouteId) routeName.value = name;
      fillRouteList();
    });
    renameInput.addEventListener('blur', () => {
      commitRouteName(index, renameInput.value);
      renameInput.classList.add('hidden');
      text.classList.remove('hidden');
    });
    label.append(text, renameInput);
    label.addEventListener('click', (event) => { event.stopPropagation(); commitSnapshot(); selectRoute(route.id); });
    label.addEventListener('dblclick', (event) => { event.stopPropagation(); openRouteRename(index); });
    routeNameWidgets.push({ label, text, input: renameInput });
    markers.push(new maplibregl.Marker({ element: label, anchor: 'left', offset: [10, 0] }).setLngLat([mid.lon, mid.lat]).addTo(map));
  });
  waypoints.forEach((waypoint, index) => {
    const wrap = document.createElement('div');
    wrap.className = 'waypoint-marker-wrap';
    const el = document.createElement('button');
    el.className = `waypoint-marker ${selectedWaypointIndex === index ? 'selected' : ''}`;
    el.type = 'button';
    el.title = waypoint.name;
    const label = document.createElement('span');
    label.className = `waypoint-map-label ${selectedWaypointIndex === index ? 'editable' : ''}`;
    label.textContent = waypoint.name;
    label.title = waypoint.name;
    const renameInput = document.createElement('input');
    renameInput.type = 'text';
    renameInput.className = 'waypoint-name-input';
    renameInput.classList.add('hidden');
    renameInput.value = waypoint.name;
    renameInput.spellcheck = false;
    renameInput.addEventListener('keydown', (event) => {
      event.stopPropagation();
      if (event.key === 'Enter' || event.key === 'Escape') renameInput.blur();
    });
    renameInput.addEventListener('input', () => sizeRenameInput(renameInput, renameInput.value));
    renameInput.addEventListener('blur', () => {
      commitWaypointName(index, renameInput.value);
      renameInput.classList.add('hidden');
      label.classList.remove('hidden');
    });
    wrap.append(el, label, renameInput);
    el.addEventListener('click', (event) => { event.stopPropagation(); selectedWaypointIndex = index; selectedIndex = null; refreshMarkers(); updateUI(); });
    el.addEventListener('dblclick', (event) => { event.stopPropagation(); openWaypointRename(index); });
    label.addEventListener('click', (event) => { event.stopPropagation(); selectedWaypointIndex = index; selectedIndex = null; refreshMarkers(); updateUI(); });
    label.addEventListener('dblclick', (event) => { event.stopPropagation(); openWaypointRename(index); });
    el.addEventListener('pointerdown', (event) => {
      event.stopPropagation();
      if (event.button !== 0) return;
      selectedWaypointIndex = index;
      selectedIndex = null;
      refreshMarkers();
      updateUI();
      map.dragPan.disable();
      const move = (e: PointerEvent) => {
        const rect = map.getCanvas().getBoundingClientRect();
        const lngLat = map.unproject([e.clientX - rect.left, e.clientY - rect.top]);
        waypoints[index] = { ...waypoints[index], lat: lngLat.lat, lon: lngLat.lng };
        refreshMarkers();
      };
      const up = () => {
        document.removeEventListener('pointermove', move);
        document.removeEventListener('pointerup', up);
        map.dragPan.enable();
        commitSnapshot();
      };
      document.addEventListener('pointermove', move);
      document.addEventListener('pointerup', up, { once: true });
    });
    waypointMarkerElements.push(el);
    waypointMarkerLabels.push(label);
    waypointNameInputs.push(renameInput);
    markers.push(new maplibregl.Marker({ element: wrap, anchor: 'center' }).setLngLat([waypoint.lon, waypoint.lat]).addTo(map));
  });
}

function snapshot(): AppState { return structuredClone({ routes, waypoints }); }
function commitSnapshot() { history.push(snapshot()); if (history.length > 50) history.shift(); future.length = 0; }
function restore(state: AppState) {
  routes = state.routes;
  waypoints = state.waypoints;
  if (!routes.some((route) => route.id === selectedRouteId)) selectedRouteId = routes[0]?.id ?? null;
  selectedIndex = null;
  selectedWaypointIndex = null;
  refreshRoutesLayer();
  updateUI();
  void refreshRouteStats();
}
function undo() { const previous = history.pop(); if (!previous) return; future.push(snapshot()); restore(previous); }
function redo() { const next = future.pop(); if (!next) return; history.push(snapshot()); restore(next); }

function newRoute(): Route {
  const id = nextRouteId++;
  return { id, name: `Route ${id}`, points: [], color: routeColorForId(id) };
}

function selectRoute(id: number | null) {
  selectedRouteId = id;
  selectedIndex = null;
  selectedWaypointIndex = null;
  refreshMarkers();
  updateUI();
  void refreshRouteStats();
}

function startDrawing() {
  if (waypointMode) setWaypointMode(false);
  if (!activeRoute()) {
    const created = newRoute();
    routes.push(created);
    commitSnapshot();
    selectRoute(created.id);
  }
  drawing = true;
  $('draw-route').classList.add('active');
  drawHint.textContent = 'Click to add route points · double-click to finish · Esc to cancel';
  drawHint.classList.remove('hidden');
  map.getCanvas().style.cursor = 'crosshair';
}
function stopDrawing() {
  drawing = false;
  $('draw-route').classList.remove('active');
  drawHint.classList.add('hidden');
  map.getCanvas().style.cursor = '';
}
function setWaypointMode(on: boolean) {
  waypointMode = on;
  $('add-waypoint').classList.toggle('active', on);
  if (on) {
    stopDrawing();
    drawHint.textContent = 'Click to place a waypoint · Esc to cancel';
    drawHint.classList.remove('hidden');
    map.getCanvas().style.cursor = 'copy';
  } else {
    drawHint.classList.add('hidden');
    map.getCanvas().style.cursor = '';
  }
}

function addWaypoint(event: MapMouseEvent) {
  commitSnapshot();
  waypoints.push({ lat: event.lngLat.lat, lon: event.lngLat.lng, name: `Waypoint ${waypoints.length + 1}` });
  selectedWaypointIndex = waypoints.length - 1;
  selectedIndex = null;
  setWaypointMode(false);
  refreshMarkers();
  updateUI();
}

function addRoutePoint(event: MapMouseEvent) {
  const route = activeRoute();
  if (!route) return;
  commitSnapshot();
  route.points.push({ lat: event.lngLat.lat, lon: event.lngLat.lng });
  selectedIndex = route.points.length - 1;
  selectedWaypointIndex = null;
  refreshRoutesLayer();
  updateUI();
  void refreshRouteStats();
}

map.on('click', (event: MapMouseEvent) => {
  if (rotating || rotatedThisGesture) return;
  if (waypointMode) addWaypoint(event);
  else if (drawing) addRoutePoint(event);
});
map.on('dblclick', (event: MapMouseEvent) => {
  if (!drawing) return;
  event.preventDefault();
  const route = activeRoute();
  if (route && route.points.length >= 2) {
    const a = route.points[route.points.length - 1], b = route.points[route.points.length - 2];
    if (Math.abs(a.lat - b.lat) < 1e-9 && Math.abs(a.lon - b.lon) < 1e-9) route.points.pop();
  }
  stopDrawing();
  refreshRoutesLayer();
  updateUI();
  void refreshRouteStats();
});

window.addEventListener('keydown', (event) => {
  const typingInField = event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement;
  if (typingInField) return;
  if (event.key === 'Escape') {
    if (drawing) { stopDrawing(); return; }
    if (waypointMode) { setWaypointMode(false); return; }
  }
  const metaOrCtrl = event.metaKey || event.ctrlKey;
  if (metaOrCtrl && event.key.toLowerCase() === 'z') { event.preventDefault(); event.shiftKey ? redo() : undo(); }
  if (event.key === 'Delete') {
    if (selectedWaypointIndex !== null) {
      commitSnapshot();
      waypoints.splice(selectedWaypointIndex, 1);
      selectedWaypointIndex = null;
      refreshMarkers();
      updateUI();
    } else if (selectedIndex !== null) {
      const route = activeRoute();
      if (route) {
        commitSnapshot();
        route.points.splice(selectedIndex, 1);
        selectedIndex = null;
        refreshRoutesLayer();
        updateUI();
        void refreshRouteStats();
      }
    }
  }
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
$('add-waypoint').addEventListener('click', () => setWaypointMode(!waypointMode));
$('new-route').addEventListener('click', () => { commitSnapshot(); stopDrawing(); routes.push(newRoute()); selectRoute(routes[routes.length - 1].id); updateUI(); });
$('undo').addEventListener('click', undo);
$('redo').addEventListener('click', redo);
routeName.addEventListener('input', () => {
  const route = activeRoute();
  if (!route) return;
  const name = routeName.value || 'Unnamed route';
  route.name = name;
  const widget = routeNameWidgets[routes.indexOf(route)];
  if (widget) {
    widget.input.value = name;
    widget.text.textContent = name;
    widget.label.title = name;
  }
  fillRouteList();
});
function sizeRenameInput(input: HTMLInputElement, value: string) {
  input.style.width = `${Math.max(value.length, 6) + 2}ch`;
}

function openWaypointRename(index: number) {
  selectedWaypointIndex = index;
  selectedIndex = null;
  refreshMarkers();
  updateUI();
  const input = waypointNameInputs[index];
  if (input) {
    input.classList.remove('hidden');
    sizeRenameInput(input, input.value);
    const label = waypointMarkerLabels[index];
    if (label) label.classList.add('hidden');
    input.focus();
    input.select();
  }
}

function commitWaypointName(index: number, raw: string) {
  if (index < 0 || index >= waypoints.length) return;
  waypoints[index] = { ...waypoints[index], name: normalizeWaypointName(raw, index) };
  const label = waypointMarkerLabels[index];
  const markerButton = waypointMarkerElements[index];
  if (label) { label.textContent = waypoints[index].name; label.title = waypoints[index].name; }
  if (markerButton) markerButton.title = waypoints[index].name;
}

function openRouteRename(index: number) {
  const widget = routeNameWidgets[index];
  if (!widget) return;
  sizeRenameInput(widget.input, widget.input.value);
  widget.input.classList.remove('hidden');
  widget.text.classList.add('hidden');
  widget.input.focus();
  widget.input.select();
}

function commitRouteName(index: number, raw: string) {
  if (index < 0 || index >= routes.length) return;
  routes[index] = { ...routes[index], name: normalizeRouteName(raw, routes[index].id) };
  const widget = routeNameWidgets[index];
  const name = routes[index].name;
  if (widget) {
    widget.input.value = name;
    widget.text.textContent = name;
    widget.label.title = name;
  }
  if (routes[index].id === selectedRouteId) routeName.value = name;
  fillRouteList();
}

$('fit-route').addEventListener('click', fitAll);

$('units-metric').addEventListener('click', () => setUnitSystem('metric'));
$('units-imperial').addEventListener('click', () => setUnitSystem('imperial'));
function setUnitSystem(system: UnitSystem) {
  unitSystem = system;
  $('units-metric').classList.toggle('active', system === 'metric');
  $('units-imperial').classList.toggle('active', system === 'imperial');
  updateUI();
  drawProfileChart();
}

$('terrain-toggle').addEventListener('click', () => {
  terrainEnabled = !terrainEnabled;
  if (terrainEnabled) { applyTerrain(); map.easeTo({ pitch: 55, duration: 600 }); }
  else { applyTerrain(); map.easeTo({ pitch: 0, duration: 600 }); }
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
  const { center, zoom, bearing, pitch } = { center: map.getCenter(), zoom: map.getZoom(), bearing: map.getBearing(), pitch: map.getPitch() };
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
    // Files we exported carry DEM-sampled elevations; they may be stale, so ignore them and re-query the terrain.
    const stripElevations = doc.documentElement.getAttribute('creator') === 'GPX Plotter';
    const nextRoutes = imported.routes.map(({ name, points }) => ({
      ...newRoute(),
      name,
      points: stripElevations ? points.map(({ lat, lon }) => ({ lat, lon })) : points,
    }));
    commitSnapshot();
    routes = nextRoutes;
    waypoints = imported.waypoints;
    selectedRouteId = routes[0]?.id ?? null;
    selectedIndex = null;
    selectedWaypointIndex = null;
    refreshRoutesLayer();
    updateUI();
    fitAll();
    await refreshRouteStats();
    refreshRoutesLayer();
  } catch (error) { alert(error instanceof Error ? error.message : 'Unable to import GPX.'); }
  finally { input.value = ''; }
});

$('export-gpx').addEventListener('click', () => {
  const usable = routes.filter((route) => route.points.length >= 2);
  if (!usable.length && !waypoints.length) { alert('Add at least two route points (or a waypoint) before exporting.'); return; }
  const blob = new Blob([exportGPX(routes, waypoints)], { type: 'application/gpx+xml;charset=utf-8' });
  const url = URL.createObjectURL(blob); const anchor = document.createElement('a'); anchor.href = url;
  const base = (usable[0]?.name || 'route').replace(/[^a-z0-9-_]+/gi, '-').replace(/^-|-$/g, '') || 'route';
  anchor.download = `${base}.gpx`;
  anchor.click(); URL.revokeObjectURL(url);
});

function fitAll() {
  const points = [
    ...routes.flatMap((route) => route.points),
    ...waypoints.map((w) => ({ lat: w.lat, lon: w.lon })),
  ];
  if (!points.length) return;
  const bounds = new maplibregl.LngLatBounds();
  for (const point of points) bounds.extend([point.lon, point.lat]);
  map.fitBounds(bounds, { padding: 80, duration: 700, maxZoom: 15 });
}

function fillRouteList() {
  routesList.innerHTML = '';
  routes.forEach((route) => {
    const item = document.createElement('div');
    item.className = `route-item ${route.id === selectedRouteId ? 'selected' : ''}`;
    const swatch = document.createElement('span');
    swatch.className = 'route-swatch';
    swatch.style.background = route.color;
    const name = document.createElement('span');
    name.className = 'route-name';
    name.textContent = route.name;
    name.title = route.name;
    const remove = document.createElement('button');
    remove.className = 'route-remove';
    remove.type = 'button';
    remove.title = `Delete ${route.name}`;
    remove.textContent = '✕';
    remove.addEventListener('click', (event) => {
      event.stopPropagation();
      commitSnapshot();
      routes = routes.filter((r) => r.id !== route.id);
      if (selectedRouteId === route.id) selectedRouteId = null;
      refreshRoutesLayer();
      updateUI();
      void refreshRouteStats();
    });
    item.append(swatch, name, remove);
    item.addEventListener('click', () => { commitSnapshot(); selectRoute(route.id); });
    routesList.append(item);
  });
  routesEmpty.classList.toggle('hidden', routes.length > 0);
  routeName.disabled = !activeRoute();
}

function updateUI() {
  const route = activeRoute();
  const distance = route ? routeDistanceMeters(route.points) : 0;
  $('distance').textContent = route && route.points.length >= 2 ? formatDistance(distance, unitSystem) : '—';
  $('gain').textContent = formatElevation(routeStats.gain, unitSystem);
  $('loss').textContent = formatElevation(routeStats.loss, unitSystem);
  $('min-elevation').textContent = formatElevation(routeStats.min, unitSystem);
  $('max-elevation').textContent = formatElevation(routeStats.max, unitSystem);
  $('point-count').textContent = String(route?.points.length ?? 0);
  $('max-slope').textContent = formatSlope(routeStats.maxSlope);
  $('waypoint-count').textContent = String(waypoints.length);
  $('slope-note').textContent = !route
    ? 'Select a route to see terrain stats'
    : routeStats.gain === undefined
      ? 'Terrain stats will appear as the route grows'
      : 'Gain/loss/low/high follow the terrain along the route';
  routeName.value = route?.name ?? '';
  fillRouteList();
}

// --- Elevation profile chart -------------------------------------------------
const PROFILE_PAD_L = 38;
const PROFILE_PAD_R = 10;
const PROFILE_PAD_T = 10;
const PROFILE_PAD_B = 20;

/** Resampled terrain along the selected route; the same data that drives gain/loss stats. */
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
  const distanceUnit = unitSystem === 'imperial' ? 'mi' : 'km';
  const gridCount = 3;
  for (let g = 0; g <= gridCount; g++) {
    const value = geometry.yMin + ((geometry.yMax - geometry.yMin) * g) / gridCount;
    const y = yAt(value);
    context.beginPath();
    context.moveTo(PROFILE_PAD_L, y);
    context.lineTo(cssWidth - PROFILE_PAD_R, y);
    context.stroke();
    const label = formatElevation(value, unitSystem).replace(/\s?(ft|m)$/, '');
    context.fillText(label, 2, y + 3);
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
      const label = t === ticks[ticks.length - 1] ? `${formatDistanceAxis(t, unitSystem)} ${distanceUnit}` : formatDistanceAxis(t, unitSystem);
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
  profileReadout.textContent = `${formatDistance(geometry.cumulative[index], unitSystem)} · ${formatElevation(point.elevation, unitSystem)}`;
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

setUnitSystem(unitSystem);