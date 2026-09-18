# Architecture

This document describes the full architecture of the GPX Route Plotter: how the
code is organized, how state flows through the app, and how the map, terrain,
and elevation features are implemented.

## 1. Overview

The app is a **static, single-page, client-side application**. There is no
server component: the browser parses GPX files, samples terrain from MapTiler
tiles, computes statistics, renders the map with MapLibre GL JS, and generates
the export file locally. The only network traffic is to MapTiler for map styles,
vector/raster basemap tiles, Terrain-RGB DEM tiles, geocoding search requests,
and (for drawing/waypoint snapping) the outdoor and planet vector tilesets.

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
src/mvt.ts            Minimal MapTiler vector tile (MVT) decoder
src/snap.ts           Pure snapping math (points → trails / peaks)
src/snapSources.ts    Trail + peak tile fetching and caching for snapping
src/trailGraph.ts     Shortest-path routing along a trail network
src/geocode.ts        MapTiler geocoding search (peaks, towns, trails, trailheads)
src/merge.ts          Route merging: join two routes at nearest endpoints, trim seam overlap
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
- **State**: `routes`, `waypoints`, selection indices, mode flags, units, the
  undo/redo stacks, and the document/map name (`documentName`, set via the
  top-of-sidebar "Map name" field — it drives the tab title, the export
  filename, and the GPX metadata name). The workspace (routes, waypoints, name,
  units, view) is autosaved to `localStorage` with the "Clear" footer button
  resetting it.
- **Rendering**: updates GeoJSON sources, rebuilds DOM `Marker`s for route
  points, route labels, waypoints, and the profile hover marker.
- **Interaction**: map click/drag handlers, keyboard shortcuts, toolbar
  buttons, rename inputs, and the import dialog.
- **Stats & profile**: resamples the active route, fills DEM elevations, writes
  the sidebar numbers, and draws the elevation chart to a canvas.

### `src/storage.ts` — workspace persistence

No DOM, no map access. Reads and writes the whole workspace as a versioned JSON
blob under a single `localStorage` key:

- `saveWorkspace(data)` serializes the current routes, waypoints, id counter,
  map name, units, and map view.
- `loadWorkspace()` restores it, validating the version and shape and filling
  sane defaults; any corruption or version mismatch yields `null`.
- `clearWorkspace()` forgets the saved state (used by the "Clear" flow).
- All calls degrade gracefully when `localStorage` is unavailable or full.

### `src/gpx.ts` — GPX parsing and serialization

- Defines the core types: `RoutePoint`, `Route`, `Waypoint`, `ParsedGPX`.
- `parseGPX(xml)` reads `<trk>/<trkseg>/<trkpt>`, falls back to `<rte>/<rtept>`,
  reads `<wpt>` waypoints, and surfaces the file-level `<metadata><name>` as
  `metadataName` (namespaces ignored via `getElementsByTagNameNS('*', …)`).
  It preserves `<ele>` and throws on invalid XML or empty files.
- `exportGPX(routes, waypoints, name?)` writes a GPX 1.1 document with one
  `<trk>` per route plus `<wpt>` elements, marked `creator="GPX Plotter"`. The
  optional `name` lands in `<metadata><name>` (falling back to the first route's
  name) so the map name round-trips through re-import. That creator string is
  later used on import to detect files produced by this app.

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

### `src/mvt.ts` — MapTiler vector tile decoding

A small, dependency-free Mapbox Vector Tile decoder for the two tilesets used in
snapping:

- Parses a tile's layer names, feature geometries, and properties from the raw
  PBF bytes (varint + zigzag decoding, command-integer command counts).
- Properties are resolved in a **second pass**: real MapTiler tiles can emit
  features *before* their keys/values dictionaries, so raw features are buffered
  and their tag indices resolved once the dictionaries arrive. Value types follow
  the spec: field 4 is `values`, field 5 `extent`, and numeric values use field 6
  (`sint_value`, zigzag-encoded).
- `layerByName(tile, name)` pulls one layer's features as `{ type, props, parts }`
  (type 1 = Point, 2 = LineString, 3 = Polygon), and `tilePointToLngLat()`
  converts a point from tile coordinates to geodetic `{ lon, lat }` at the tile's
  (x, y, z).

### `src/snap.ts` — snapping math (pure)

No I/O or DOM. Given `(lng, lat)` and a set of candidate geometries, finds the
best snap target:

- `nearestOnLine(plng, plat, line)` — projects the point onto each segment of a
  polyline in meter space (`projectToSegment`) and returns the closest on-line
  point, its `distanceMeters`, and the matched `segment` (`a`, `b`, `t`).
- `nearestLine(lng, lat, lines)` — same, but also returns the polyline the match
  came from; this is what trail-following needs.
- `nearestSnap(lng, lat, candidates)` — picks the nearest candidate among trail
  lines and points, respecting thresholds `TRAIL_SNAP_METERS = 40` and
  `PEAK_SNAP_METERS = 250`. No candidate within range → `null`.
- `TRAIL_FOLLOW_METERS = 15` — the tighter radius within which the route is
  allowed to run *along* the trail (see `trailGraph`).

### `src/trailGraph.ts` — routing along trails (pure)

Given the polylines near a click, finds the shortest chain of trail vertices
between two snapped points so the route hugs the trail:

- Polylines are deduplicated (the same trail can appear in both tilesets) and
  vertices are indexed by rounded coordinates. Consecutive vertices become
  weighted edges (edge weight = meter distance).
- A single OSM way is often split into several features, so loose endpoints
  within `TRAIL_JOIN_METERS` (25 m) are bridged into one connected network.
- The two snapped points are added as nodes attached to their projected
  segment, then Dijkstra finds the shortest path between them.
- `TRAIL_MAX_DETOUR` (4×) rejects anything that wanders far more than a straight
  line (or is unreachable), returning `null` so the caller draws straight.

### `src/snapSources.ts` — trail & peak tile sourcing

Fetches and caches the vector tiles the snap layers need:

- Trails come from the **outdoor** tileset's `trail` layer *and* the **planet**
  tileset's `transportation` layer filtered to path-like classes (`path`,
  `footway`, `steps`, `track`, `cycleway`, `bridleway`, `pedestrian`,
  `corridor`). The `trail` layer only carries trails that belong to a route
  relation, so many ordinary paths (e.g. Redneck Ridge) exist only in
  `transportation`; reading both is what makes snapping work broadly. Peaks come
  from the planet `mountain_peak` layer.
- `trailsNearPoint(lng, lat)` returns every trail/path polyline in the
  containing tile; `peaksNearPoint(lng, lat)` returns peaks with `name` and
  `elevation` (meters) from their properties. Both are at zoom 13 and share a
  96-tile LRU cache (planet tiles are reused between trails and peaks).
- Any fetch/decode failure degrades to `[]` so drawing always works offline.

### `src/geocode.ts` — geocoding search

Pure fetch/parse, no DOM or MapLibre:

- `geocodeUrl(query, options)` — builds the MapTiler forward-geocoding URL,
  pinned to `GEOCODE_TYPES`
  (`municipality,place,locality,poi,major_landform,address`) so results stay
  relevant to hiking (towns/municipalities, peaks/POIs, mountain ranges, and
  trails/backcountry ways). MapTiler indexes named trails, paths, and
  backcountry roads as `address` features (kind `street`), so `address` is what
  makes trail names searchable. An optional `proximity` (the current map center)
  biases the API's ranking toward where the user is looking, so local features
  outrank far-flung namesakes.
- `geocode(query, options)` — `fetch`es the API, normalizes features, and never
  throws: blanks, non-OK responses, and network failures all return `[]`.
- `normalizeFeature` — maps a raw GeoJSON feature to a `GeocodeResult`
  (`name`, `region`, friendly `typeLabel`, optional summit `elevation`, `center`,
  optional `bbox`), skipping non-Point geometry or invalid coordinates. Peaks
  are detected via `feature_tags.natural === "peak"` / the `peak` category and
  labeled **Peak** (summit elevation read from `feature_tags.ele`); POIs whose
  name contains "trailhead" are labeled **Trailhead**; `address`/street features
  whose name looks like a trail (`TRAIL_NAME`) are labeled **Trail**, and other
  indexed ways **Street**. For non-settlements the region is rebuilt from the
  county/state/country context (`"Alamosa, Colorado, USA"`), since `place_name`
  often drops the state.
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

### `src/merge.ts` — combining two routes (pure)

- `mergeRoutePoints(a, b, overlapMeters = 10)` — returns one continuous trace.
  `orientMerge` tries the four start/end pairings and joins the endpoints that
  are nearest (reversing a route when that pairing is cheapest), then
  `trimDuplicatedHead` walks the joint outward and drops the second route's
  duplicated head while the two traces stay within `overlapMeters` of each
  other and are heading the *same* direction — an opposite-direction return
  (out-and-back) is always preserved. Straight-line geometry comes from
  `snap.ts`, so no map or DOM is involved.

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
| `snap-preview` | `geojson` | Hover snap preview (dashed line + dot) |
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
  there are ≥ 2 points; Enter finishes, Esc cancels. While drawing, hovering
  computes the same snap and shows a dashed preview line + blue dot (the
  `snap-preview` source), so the pending point is visible on the trail before the
  click. Each new point is pushed immediately and then refined asynchronously by
  `snapRoutePointToTrail()`: the containing outdoor + planet tiles are decoded
  and, if the point is within 40 m of a trail, it moves onto the trail. When the
  point is within `TRAIL_FOLLOW_METERS` (15 m) and the previous point is also on
  the network, `routeAlongTrails()` splices in the trail's own vertices so the
  route follows the trail between clicks. The refine is checked both ways (the
  point must still be the last one and the route still the active one) so a stale
  result can never rewrite a newer point.
- **Waypoint mode** (`waypointMode`): one click places a single waypoint, then
  the mode exits automatically. `snapWaypointToPeak()` runs the same way against
  `mountain_peak` points (250 m radius); a snapped waypoint inherits the peak's
  name and elevation.
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
  `colors`, `names`, `merge`, `simplify`, `config`, `storage`, `mvt`, `snap`,
  `snapSources`, `trailGraph`).
- CI (`.github/workflows/pr.yml`) builds and tests on pushes/PRs.
- Deployment (`.github/workflows/deploy.yml`) publishes the main build to the
  `gh-pages` branch root on pushes to `main`; GitHub Pages serves that branch.
- PR previews (`.github/workflows/preview.yml`) publish each PR commit to
  `preview/<branch>/` on the same `gh-pages` branch (so main and previews coexist
  on one Pages site) and comment the URL on the PR.

## 14. Known limitations

- All state lives in memory and is autosaved to `localStorage`; a cleared cache
  or a different browser loses the workspace (GPX export is the portable copy).
- Elevation stats and the profile depend on DEM availability and are only as
  accurate as the ~30 m sampling.
- Trail/peak snapping depends on the MapTiler tilesets being reachable and
  complete; when they are not, drawing and waypoints degrade to raw placement
  with no error surfaced. Only the single z13 tile containing the click is read
  (plus the previous point's tile when following), so a trail just across a tile
  edge may be missed.
- Following a trail uses only the geometry present in the decoded tiles; if a
  trail leaves the tile, the route falls back to a straight segment.
- Very large "keep every point" imports still create one DOM marker per point
  and can be slow.
- GPX metadata (time, heart rate, etc.) beyond coordinates/elevation/name is not
  preserved.
