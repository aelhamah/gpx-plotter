# Architecture

This document describes the full architecture of the GPX Route Plotter: how the
code is organized, how state flows through the app, and how the map, terrain,
and elevation features are implemented.

## 1. Overview

The app is a **static, single-page, client-side application**. There is no
server component: the browser parses GPX files, samples terrain from MapTiler
tiles, computes statistics, renders the map with MapLibre GL JS, and generates
the export file locally. The only network traffic is to MapTiler for map styles,
vector/raster basemap tiles, Terrain-RGB DEM tiles, and geocoding search requests.

Consequences:

- No database, login, or API keys beyond the public MapTiler browser key.
- All state is ephemeral and lives in memory; a page reload starts fresh.
- GPX files never leave the user's machine.

## 2. Technology stack

| Concern | Choice |
| --- | --- |
| Language | TypeScript (strict, `tsc -b`) |
| Build/dev server | Vite |
| Map rendering | MapLibre GL JS |
| Basemaps & terrain | MapTiler (Outdoor, Satellite, Terrain-RGB) |
| Tests | Vitest + jsdom |
| Deployment | GitHub Pages via GitHub Actions |

## 3. Repository layout

```
index.html            Static shell: sidebar, map container, controls, dialogs
src/main.ts           Application hub: map, state, DOM wiring, markers, chart
src/gpx.ts            GPX parse + serialize, core data types
src/geo.ts            Geodesy, elevation stats, route resampling, chart math
src/dem.ts            MapTiler Terrain-RGB decoding + slope raster generation
src/geocode.ts        MapTiler geocoding search (peaks, towns, landforms)
src/simplify.ts       Track downsampling (import of large files)
src/units.ts          Metric/imperial defaults + formatting
src/colors.ts         Route color palette + profile trace color
src/names.ts          Fallback names for routes and waypoints
src/config.ts         MapTiler URLs, API key, default camera
src/style.css         All styling (glass sidebar, toolbars, markers, dialogs)
public/demos/*.gpx    Sample tracks (e.g. a 13k-point hike)
tests/*.test.ts       Unit tests for the pure modules
docs/                 This document, the feature list, and the dev guide
```

## 4. Module responsibilities

### `src/main.ts` — the application hub

This is intentionally the largest file. It owns everything that touches the DOM
or the map and coordinates the pure modules:

- **Map lifecycle**: creates the `maplibregl.Map`, adds navigation/attribution
  controls, registers the custom `slope://` protocol, and (re)builds data
  sources/layers on `load` and on every `style.load`.
- **State**: `routes`, `waypoints`, selection indices, mode flags, units, and
  the undo/redo stacks.
- **Rendering**: updates GeoJSON sources, rebuilds DOM `Marker`s for route
  points, route labels, waypoints, and the profile hover marker.
- **Interaction**: map click/drag handlers, keyboard shortcuts, toolbar
  buttons, rename inputs, and the import dialog.
- **Stats & profile**: resamples the active route, fills DEM elevations, writes
  the sidebar numbers, and draws the elevation chart to a canvas.

### `src/gpx.ts` — GPX parsing and serialization

- Defines the core types: `RoutePoint`, `Route`, `Waypoint`, `ParsedGPX`.
- `parseGPX(xml)` reads `<trk>/<trkseg>/<trkpt>`, falls back to `<rte>/<rtept>`,
  and reads `<wpt>` waypoints (namespaces ignored via `getElementsByTagNameNS('*', …)`).
  It preserves `<ele>` and throws on invalid XML or empty files.
- `exportGPX(routes, waypoints)` writes a GPX 1.1 document with one `<trk>` per
  route plus `<wpt>` elements, marked `creator="GPX Plotter"`. That creator
  string is later used on import to detect files produced by this app.

### `src/geo.ts` — geodesy and profiles

Pure math, no DOM:

- `haversineMeters` / `routeDistanceMeters` — great-circle distances.
- `elevationStats` / `summarizeProfile` / `segmentSlopeDegrees` — gain, loss,
  min/max elevation, and steepest segment angle.
- `routeProfilePoints(points, stepMeters)` — resamples long segments along their
  drawn (Mercator-straight) path so stats reflect the terrain *crossed between*
  vertices, not just the vertices.
- `profileAxisStep` / `nearestProfileSample` — chart axis ticks and hover
  snapping.
- `metersToMiles` / `metersToFeet` / `metersToKm`, `colorToAlpha`, and
  Mercator helpers.

### `src/dem.ts` — Terrain-RGB decoding and slope shading

- `elevationAt(lng, lat)` — bilinear terrain elevation in meters at any point,
  decoded client-side from MapTiler Terrain-RGB tiles
  (`-10000 + (R·65536 + G·256 + B)·0.1`). Used to fill missing elevations.
- Tile cache + in-flight de-duplication (`Map` + `pending`), capped at 400 tiles.
- `slopeRgba` / `slopeCanvasForTile` — colorize a DEM tile by slope angle into
  avalanche bands (`<20°`, `20–30°`, `30–35°`, `35–40°`, `40–45°`, `45°+`).
- Decoding tries `createImageBitmap` first and falls back to an `<img>` for
  engines that cannot decode WebP bitmaps.

### `src/geocode.ts` — geocoding search

Pure fetch/parse, no DOM or MapLibre:

- `geocodeUrl(query, limit)` — builds the MapTiler forward-geocoding URL, pinned
  to `GEOCODE_TYPES` (`municipality,place,locality,poi,major_landform`) so
  results stay relevant to hiking (towns/municipalities, peaks/POIs, and
  mountain ranges).
- `geocode(query)` — `fetch`es the API, normalizes features, and never throws:
  blanks, non-OK responses, and network failures all return `[]`.
- `normalizeFeature` — maps a raw GeoJSON feature to a `GeocodeResult`
  (`name`, `region`, friendly `typeLabel`, `center`, optional `bbox`), skipping
  non-Point geometry or invalid coordinates.
- `placeTypeLabel` — human-friendly badges, preferring the OSM `place_designation`
  (City/Town/Village) over the broader place type.

`main.ts` owns the search-bar DOM: debounced type-ahead, ↑/↓/Enter/Esc keyboard
handling, and `selectSearchResult()`, which frames the map (`fitBounds` when the
feature has a `bbox`, otherwise a point zoom) and shows a temporary, non-waypoint
marker.

### `src/simplify.ts` — importing large tracks

- `downsamplePoints(points, maxPoints)` — thins a dense track by walking it and
  keeping a point only once it is at least `threshold` from the last kept point,
  always keeping the first and last. A 24-iteration binary search finds the
  smallest threshold whose result still fits `maxPoints`, so output lands close
  to the target. Long tracks create one DOM marker per point, so this is what
  keeps large imports usable.
- `defaultPointBudget(distanceMeters, pointCount)` — suggests a point budget at
  roughly one point every `DOWNSAMPLE_DEFAULT_SPACING_METERS` (15 m), so the
  suggested downsampling scales with route length.
- `DOWNSAMPLE_PROMPT_THRESHOLD` (500) — imports larger than this open the dialog.

### `src/units.ts`, `src/colors.ts`, `src/names.ts`

- `units.ts`: `defaultUnitSystem()` (imperial for `US` locales, else metric) and
  all formatting (`formatDistance`, `formatElevation`, `formatSlope`,
  `formatDistanceAxis`).
- `colors.ts`: the deterministic `ROUTE_COLORS` palette (`routeColorForId`) and
  `TRACE_COLOR` for the profile hover trace.
- `names.ts`: `normalizeRouteName` / `normalizeWaypointName` fallbacks.

## 5. Data model

```ts
interface RoutePoint { lat: number; lon: number; elevation?: number; }
interface Route      { id: number; name: string; points: RoutePoint[]; color: string; }
interface Waypoint   { lat: number; lon: number; name: string; elevation?: number; }
```

Elevation is optional everywhere: imported GPX may lack `<ele>`, and drawn
points never have it. Missing elevations are filled from the DEM on demand
(stats sampling, or once per waypoint for its label).

## 6. Application state and undo/redo

All mutable state is module-scoped in `main.ts`:

- `routes: Route[]`, `waypoints: Waypoint[]`
- `selectedRouteId`, `selectedIndex` (selected route point), `selectedWaypointIndex`
- `drawing`, `waypointMode`
- `terrainEnabled`, `reliefEnabled`, `satelliteEnabled`, `slopeEnabled`
- `unitSystem`
- `history: AppState[]`, `future: AppState[]` (bounded to 50 snapshots)

Undo/redo is **document-level**: `snapshot()` deep-clones `{ routes, waypoints }`
via `structuredClone`, and `commitSnapshot()` is called *before* every mutation
(add/move/rename/delete point or waypoint, import, new route). `undo()`/`redo()`
swap snapshots and call `restore()`, which re-renders layers, UI, stats, and
waypoint elevations.

## 7. Map, layers, and terrain

The map is created with the Outdoor style. On `load` and on every `style.load`
(the latter fires after style swaps such as switching to satellite), the app
calls `addDataLayers()` and `applyTerrain()` so custom sources/layers and 3D
terrain are re-applied — MapLibre drops them when the style is replaced.

Sources and layers:

| Source | Type | Purpose |
| --- | --- | --- |
| `terrain` | `raster-dem` | MapTiler Terrain-RGB for 3D terrain + hillshade |
| `slope` | `raster` (`slope://{z}/{x}/{y}`) | Colorized slope-angle shading |
| `routes` | `geojson` | Route lines (casing + colored line) |
| `profile-trace` | `geojson` | Highlighted trail up to the hovered profile point |

Layer order: `slope-shading` → `route-casing` → `route-line` → `profile-trace`
→ `relief` (hillshade). Visibility is toggled per the feature flags.

**Custom `slope://` protocol.** `maplibregl.addProtocol('slope', …)` decodes and
colorizes a DEM tile on demand and returns a PNG. Serving raster tiles through
the protocol (rather than a canvas overlay) keeps the shading perfectly aligned
through pan/tilt/rotate.

## 8. Stats and elevation profile

`refreshRouteStats()` is the core pipeline for the active route:

1. `routeProfilePoints(route.points, 30)` resamples the route every ~30 m.
2. Every sample without an elevation triggers `elevationAt()` (parallel
   `Promise.all`), filling terrain elevations.
3. `summarizeProfile()` computes gain/loss/low/high/max-slope.
4. `updateUI()` writes the sidebar; `drawProfileChart()` paints the chart.

A monotonically increasing `statsToken` guards against out-of-order async
results when the route changes mid-sample; `setStatsLoading()` shows the
"Reading terrain…" spinner.

The **profile chart** is a DPR-aware `<canvas>`: x is cumulative distance, y is
elevation, and each segment is stroked/filled in its slope-band color. Hovering
snaps to the nearest sample, shows a readout, draws a dashed cursor, and lights
up the matched portion of the route via the `profile-trace` layer and a DOM
hover marker.

## 9. Import pipeline

```
<input type=file> change
  → file.text()
  → DOMParser (peek creator == "GPX Plotter"?)
  → parseGPX()
  → largest route > 500 points?
        yes → open import dialog (distance-based default budget)
              → downsamplePoints() per route on confirm
        no  → import as-is
  → append to routes/waypoints (never overwrite)
  → commitSnapshot(), select first imported route, fit to imported points
  → refreshRouteStats() + fill waypoint elevations
```

Files previously exported by the app carry DEM-sampled elevations that may be
stale, so they are stripped and re-sampled from the current terrain. Imports are
**additive**: each import appends routes and waypoints and fits the view to the
new content.

## 10. Interaction model

- **Draw mode** (`drawing`): clicking the map appends points to the active route.
  A floating draw bar shows the live point count and enables **Finish** once
  there are ≥ 2 points; Enter finishes, Esc cancels.
- **Waypoint mode** (`waypointMode`): one click places a single waypoint, then
  the mode exits automatically.
- **Selection**: clicking a point marker or waypoint selects it (showing the
  edit affordance); clicking empty map deselects.
- **Dragging**: route points and waypoints are draggable; the drag disables
  `dragPan`, updates coordinates live, and re-samples elevation on release.
- **Camera**: ⌘/Ctrl-drag tilts and rotates; scroll zooms (wheel over the
  sidebar is intercepted to scroll the sidebar instead).

## 11. Performance notes

- The dominant cost is DOM markers — one per route point. Downsampling large
  imports is the main mitigation.
- Terrain sampling batches requests and caches tiles, so panning over the same
  area is cheap.
- `refreshRouteStats` is cancelled logically via `statsToken` when the route
  changes before sampling finishes.
- Imports are capped by the downsample dialog rather than by hard limits.

## 12. Configuration and secrets

`src/config.ts` reads `VITE_MAPTILER_API_KEY` from the environment and builds
the style/terrain URLs. The key is a **public browser key** and is visible in
the bundle by design; it must be origin-restricted in MapTiler. `.env.local`
(which holds the real key) is gitignored and `.env.example` is committed with a
placeholder.

## 13. Build, test, and deploy

- `npm run build` runs `tsc -b` then `vite build`; `base: './'` makes assets
  relative so the bundle works on GitHub Pages project sites.
- `npm test` runs Vitest over the pure modules (`geo`, `gpx`, `dem`, `units`,
  `colors`, `names`, `simplify`, `config`).
- CI (`.github/workflows/pr.yml`) builds and tests on pushes/PRs.
- Deployment (`.github/workflows/deploy.yml`) publishes the main build to the
  `gh-pages` branch root on pushes to `main`; GitHub Pages serves that branch.
- PR previews (`.github/workflows/preview.yml`) publish each PR commit to
  `preview/<branch>/` on the same `gh-pages` branch (so main and previews coexist
  on one Pages site) and comment the URL on the PR.

## 14. Known limitations

- All state is in memory; nothing persists across reloads.
- Elevation stats and the profile depend on DEM availability and are only as
  accurate as the ~30 m sampling.
- Very large "keep every point" imports still create one DOM marker per point
  and can be slow.
- GPX metadata (time, heart rate, etc.) beyond coordinates/elevation/name is not
  preserved.
