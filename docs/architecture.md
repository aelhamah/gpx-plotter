# Architecture

This document describes the full architecture of the GPX Route Plotter: how the
code is organized, how state flows through the app, and how the map, terrain,
and elevation features are implemented. It covers the web app in `web/`; the
planned native iOS app has its own document, [`ios-plan.md`](ios-plan.md).

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

This table is the **web** stack only. The iOS app is planned as a native
SwiftUI + MapLibre Native app — see [`ios-plan.md`](ios-plan.md).

## 3. Repository layout

The repository holds two products that share a data format but nothing else.
Each is self-contained under its own top-level directory, and CI decides which
one to build from the files a pull request touches.

```
web/                  The browser app — a self-contained Vite project
  index.html          Static shell: sidebar, map container, controls, dialogs
  src/main.ts         Application hub: map, state, DOM wiring, markers, chart
  src/gpx.ts          GPX parse + serialize, core data types
  src/geo.ts          Geodesy, elevation stats, route resampling, chart math
  src/dem.ts          MapTiler Terrain-RGB decoding + slope raster generation
  src/mvt.ts          Minimal MapTiler vector tile (MVT) decoder
  src/snap.ts         Pure snapping math (points → trails / peaks)
  src/snapTiles.ts    Pure: which zoom and tiles a snap query needs
  src/snapSources.ts  Trail + peak tile fetching and caching for snapping
  src/trailGraph.ts   Shortest-path routing along a trail network
  src/segments.ts     Pure: per-segment bearing + midpoint, screen-space thinning
  src/arrows.ts       Direction-arrow icon, GeoJSON builder, and symbol layer spec
  src/fitPadding.ts   Pure: how much of the map the sidebar covers, per edge
  src/geocode.ts      MapTiler geocoding search (peaks, towns, trails, trailheads)
  src/serviceStatus.ts  Names the service behind a failure and renders the banner
  src/locate.ts       Pure geolocation math: accuracy halo, camera zoom, permission copy
  src/merge.ts        Route merging: join two routes at nearest endpoints, trim seam overlap
  src/simplify.ts     Track downsampling (import of large files)
  src/units.ts        Metric/imperial defaults + formatting
  src/colors.ts       Route color palette + profile trace color
  src/names.ts        Fallback names for routes and waypoints
  src/config.ts       MapTiler URLs, API key, default camera
  src/style.css       All styling (glass sidebar, toolbars, markers, dialogs)
  public/demos/*.gpx  Sample tracks (e.g. a 13k-point hike)
  tests/*.test.ts     Unit tests for the pure modules
ios/                  The native iOS app (planned — see docs/ios-plan.md)
docs/                 This document, the feature list, the dev guide, the iOS plan
```

`web/` is the Vite project root, so `npm` commands run from inside it and
`base: './'` still emits relative asset URLs. `.gitignore` needs no per-directory
entries because `node_modules/` and `dist/` have no leading slash and therefore
match at any depth.

## 4. Module responsibilities

### `web/src/main.ts` — the application hub

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

### `web/src/storage.ts` — workspace persistence

No DOM, no map access. Reads and writes the whole workspace as a versioned JSON
blob under a single `localStorage` key:

- `saveWorkspace(data)` serializes the current routes, waypoints, id counter,
  map name, units, snapping preference, and map view.
- `loadWorkspace()` restores it, validating the version and shape and filling
  sane defaults; any corruption or version mismatch yields `null`.
- `snappingEnabled` is the one optional field whose default is not `undefined`:
  only an explicit `false` turns snapping off, so a workspace saved before the
  toggle existed does not silently load with snapping disabled.
- `clearWorkspace()` forgets the saved state (used by the "Clear" flow).
- All calls degrade gracefully when `localStorage` is unavailable or full.

### `web/src/gpx.ts` — GPX parsing and serialization

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

### `web/src/geo.ts` — geodesy and profiles

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

### `web/src/dem.ts` — Terrain-RGB decoding and slope shading

- `elevationAt(lng, lat)` — bilinear terrain elevation in meters at any point,
  decoded client-side from MapTiler Terrain-RGB tiles
  (`-10000 + (R·65536 + G·256 + B)·0.1`). Used to fill missing elevations.
- Tile cache + in-flight de-duplication (`Map` + `pending`), capped at 400 tiles.
- `slopeRgba` / `slopeCanvasForTile` — colorize a DEM tile by slope angle into
  avalanche bands (`<20°`, `20–30°`, `30–35°`, `35–40°`, `40–45°`, `45°+`).
- Decoding tries `createImageBitmap` first and falls back to an `<img>` for
  engines that cannot decode WebP bitmaps.
- A failed tile reports through `reportServiceFailure('elevation', …)`, which is
  how the sidebar banner learns that terrain is gone.

### `web/src/serviceStatus.ts` — Naming the service that failed

Everything remote here is optional in a way that hides its own failure: the
basemap is one style URL, elevation is a DEM tile per point, search is one
geocoding call. When one dies the app keeps working and simply shows a blank
map, a row of em dashes, and a profile that never draws — indistinguishable from
a bug in the app, with nothing for the user to act on.

- `classifyServiceFailure(message)` maps a failure to `style`, `basemap`,
  `elevation` or `search` by the URL it mentions, and returns `null` for
  anything else. MapLibre funnels style, tile and terrain-source failures through
  one `error` event that still carries the failing URL, so `main.ts` needs a
  single handler; DEM and geocoding fetch their own URLs and report through
  `reportServiceFailure` instead, which keeps the DOM out of both modules.
- `summarizeServices(issues)` collapses the current failures into one sentence,
  loudest first — a dead style subsumes terrain and search, so it leads. A 429
  additionally says the free plan ran out of request volume and should recover.
- `ServiceStatus` holds which services are unhappy and renders `#service-banner`.
  It clears a service the moment it answers again (`style.load` for the basemap,
  a profile with elevations for terrain), so a rate limit that lifts leaves
  nothing behind. Only real failures are shown: MapLibre raises errors for
  plenty of local trouble the user cannot act on.

### `web/src/mvt.ts` — MapTiler vector tile decoding

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

### `web/src/snap.ts` — snapping math (pure)

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
- `TRAIL_SNAP_METERS` doubles as the test for whether a snapped point should then
  run *along* its trail (see `trailGraph`): the point has already been moved onto
  the trail, so following it moves the point no further. An earlier, tighter
  15 m gate rejected legs whose points had snapped successfully.

### `web/src/snapTiles.ts` — which tiles a snap needs (pure)

Decides the zoom and the tile set for a snap query. No I/O.

- `snapZoomFor(mapZoom)` rounds and clamps the map's zoom into
  `[SNAP_MIN_ZOOM = 14, SNAP_MAX_ZOOM = 15]`. Snapping reads the tiles the
  basemap is drawing, at the depth it draws them: at z13 the planet tileset has
  already generalised away or dropped the minor paths a click is aiming at, and
  at z12 it emits no path-like `transportation` classes at all. Rounding keeps
  the cache key stable while panning at a fractional zoom.
- `TILESET_MAX_ZOOM` is `{ outdoor: 14, planet: 15 }`. Each tileset caps out at a
  different depth, and a deeper request is an HTTP 400, so `zoomForTileset`
  clamps per source — at z15 the planet source is read alone.
- `tilesNear(lng, lat, zoom, radiusMeters)` returns the containing tile plus the
  neighbours the radius actually reaches, measuring against the point's real
  distance to each tile edge. Rounding a full ring up unconditionally would cost
  nine fetches per source for the ordinary case of a click mid-tile.

### `web/src/trailGraph.ts` — routing along trails (pure)

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

### `web/src/snapSources.ts` — trail & peak tile sourcing

Fetches and caches the vector tiles the snap layers need:

- Trails come from the **outdoor** tileset's `trail` layer *and* the **planet**
  tileset's `transportation` layer filtered to path-like classes (`path`,
  `footway`, `steps`, `track`, `cycleway`, `bridleway`, `pedestrian`,
  `corridor`). The `trail` layer only carries trails that belong to a route
  relation, so many ordinary paths (e.g. Redneck Ridge) exist only in
  `transportation`; reading both is what makes snapping work broadly. Peaks come
  from the planet `mountain_peak` layer.
- `trailsNearPoint(lng, lat, zoom, radius)` and
  `peaksNearPoint(lng, lat, zoom, radius)` take the map's current zoom and the
  snap radius, ask `snapTiles` for the tiles that can hold a candidate, and
  return every trail polyline (or peak, with `name` and `elevation` in meters)
  among them. Decoded tiles share a 256-entry cache keyed by tileset/z/x/y, so
  planet tiles are reused between trails and peaks and a redraw costs no request.
- A tile that fails is dropped rather than cached, so a single 429 or 5xx costs
  its own candidates instead of disabling snapping over an area for the rest of
  the session. Tiles that do load still contribute.
- When *every* tile of a snap fails, the failure is reported to `ServiceStatus`
  as the `snap` service. Drawing still works, but the user is told the trails
  are not loading rather than being left to guess why nothing snapped.

### `web/src/geocode.ts` — geocoding search

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

### `web/src/fitPadding.ts` — fitting around the sidebar (pure)

The sidebar floats over a full-bleed map, so a symmetric `fitBounds` padding
centres routes *behind* it. `sidebarInsets(sidebarRect, containerRect)` measures
how far in from each map edge the sidebar reaches, and `fitPadding(...)` adds the
usual 80px margin on top. `main.ts`'s `mapFitPadding()` supplies the two live
rects and feeds every `fitBounds` call (the fit control, GPX import, and search
results).

The covered edge is measured rather than assumed because the sidebar changes
shape: a 330px column on the left on wide viewports, a full-width sheet along
the bottom (up to 46vh) under 800px. A hard-coded left inset would be wrong in
the narrow layout, which is why the issue this fixes looked intermittent.

### `src/simplify.ts` — importing large tracks
### `web/src/simplify.ts` — importing large tracks

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

### `web/src/merge.ts` — combining two routes (pure)

- `mergeRoutePoints(a, b, overlapMeters = 10)` — returns one continuous trace.
  `orientMerge` tries the four start/end pairings and joins the endpoints that
  are nearest (reversing a route when that pairing is cheapest), then
  `trimDuplicatedHead` walks the joint outward and drops the second route's
  duplicated head while the two traces stay within `overlapMeters` of each
  other and are heading the *same* direction — an opposite-direction return
  (out-and-back) is always preserved. Straight-line geometry comes from
  `snap.ts`, so no map or DOM is involved.

### `web/src/units.ts`, `src/colors.ts`, `src/names.ts`

- `units.ts`: `defaultUnitSystem()` (imperial for `US` locales, else metric) and
  all formatting (`formatDistance`, `formatElevation`, `formatSlope`,
  `formatDistanceAxis`).
- `colors.ts`: the deterministic `ROUTE_COLORS` palette (`routeColorForId`) and
  `TRACE_COLOR` for the profile hover trace.
- `names.ts`: `normalizeRouteName` / `normalizeWaypointName` fallbacks.

### `web/src/locate.ts` — the "my location" control (pure)

No DOM, no MapLibre, so all of it is unit-testable:

- `accuracyCirclePolygon(lon, lat, radiusMeters, steps = 64)` — a geodesic ring
  (`position → destination` on the great circle) around the fix, longitudes
  wrapped into `[-180, 180]` so a fix near the antimeridian does not draw a
  polygon around the globe.
- `locationGeoJSON(fix)` — the `location` source: a Point for the dot plus the
  accuracy Polygon, or an empty collection when the fix is cleared. A polygon
  (rather than a zoom-scaled circle layer) keeps the halo honest about how far
  off the fix can be at any zoom.
- `zoomForAccuracy(accuracyMeters, latitude, maxZoom = 15)` — the zoom that
  makes the halo about 60 px wide, from the Web Mercator ground resolution
  (`156543.03392 · cos(lat) / 2^zoom` meters per pixel); a missing accuracy
  falls back to 30 m.
- `locateErrorMessage(code)` / `locateUnavailableMessage(reason)` /
  `locateButtonLabel(unavailable, permission, located)` — the error and tooltip
  copy. Denied permission gets explicit instructions because browsers do not
  re-prompt a denied site.

`main.ts` owns the browser interaction: the permission watch (Permissions API,
click-only requests), `getCurrentPosition`, `easeTo` to the fix, and the
`busy`/`denied`/`unavailable`/`active` button states. A successful fix is silent
— the dot, the halo, and the camera move are the feedback — while failures write
to `#map-status` like every other error in the app. `setLocateStatus('')` on
success drops a stale locate error, but only when the line still holds our own
message, so another subsystem's error is never clobbered. `locationFix` is
deliberately outside `AppState` and `persistWorkspace()` — device position is
never saved or undoable.

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
- `locationFix: LocationFix | null` (last device position; memory only, never persisted)
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
| `route-arrows` | `geojson` | Direction arrows at segment midpoints (one per qualifying segment) |
| `snap-preview` | `geojson` | Hover snap preview (dashed line + dot) |
| `profile-trace` | `geojson` | Highlighted trail up to the hovered profile point |
| `location` | `geojson` | Device position dot + accuracy halo (`locationFix`) |

Layer order: `slope-shading` → `route-casing` → `route-line` → `route-points`
→ `route-arrows` → `profile-trace` → `relief` (hillshade) →
`location-accuracy` → `location-halo` → `location-dot`. Visibility is toggled
per the feature flags.

**Direction arrows.** `segments.ts` holds the geometry: for each segment it
computes the midpoint and a bearing in Web Mercator space — the space route lines
are actually drawn in, so a rotated arrow lines up with the rendered line rather
than the rhumb line through the two points. Bearings wrap across the
antimeridian. A segment earns an arrow only when it is at least 64 px long on
screen at the current zoom, so `segmentArrows()` returns fewer arrows as you zoom
out; `main.ts` recomputes the set on `zoomend`. `arrows.ts` turns that into
GeoJSON (visible routes only, active route emitted last so it draws on top) and
owns the `symbol` layer and its canvas arrow icon. Symbols are used rather than
DOM markers so the arrows stay glued to the globe and terrain.

Two details the icon depends on:

- **The chevron is drawn pointing north.** MapLibre renders an icon as authored
  at `icon-rotate: 0` and turns it clockwise from there, which is the direction
  bearings are measured in, so a north-authored icon makes
  `icon-rotate: ['get', 'bearing']` come out right. An east-authored icon would
  need the 90° offset spelled out in the layer.
- **One pre-tinted icon per color.** `icon-color` only applies to SDF images, so
  instead `addArrowImages()` renders a chevron per color (the palette, plus any
  color a route actually carries, in case an import brings its own) and each
  feature carries an `icon` id. The chevron is filled with the route color and
  stroked with nothing: it sits on a line of that same color, so a contrasting
  keyline only ever cut the line in two. The notch is what lets it read as part
  of the route — the line shows through it — and the chevron is drawn a shade
  wider than the 4 px line so the flare past the line is visible at a glance.
  Nothing dims inactive arrows either: route lines are all full opacity, and a
  translucent arrow would read as a rendering glitch rather than a quieter route.

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
  `snapRoutePointToTrail()`: the outdoor + planet tiles around the point, at the
  map's current zoom, are decoded and, if the point is within 40 m of a trail, it
  moves onto the trail. When the previous point is on the network too,
  `routeAlongTrails()` splices in the trail's own vertices so the route follows
  the trail between clicks. The refine is checked both ways (the point must still
  be the last one and the route still the active one) so a stale result can never
  rewrite a newer point.
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

`web/src/config.ts` reads `VITE_MAPTILER_API_KEY` from the environment and builds
the style/terrain URLs. The key is a **public browser key** and is visible in
the bundle by design; it must be origin-restricted in MapTiler. `.env.local`
(which holds the real key) is gitignored and `.env.example` is committed with a
placeholder.

## 13. Build, test, and deploy

- `npm run build` runs `tsc -b` then `vite build`; `base: './'` makes assets
  relative so the bundle works on GitHub Pages project sites.
- `npm test` runs Vitest over the pure modules (`geo`, `gpx`, `dem`, `units`,
  `colors`, `names`, `merge`, `simplify`, `config`, `storage`, `mvt`, `snap`,
  `snapTiles`, `snapSources`, `trailGraph`, `segments`, `arrows`, `locate`,
  `fitPadding`) plus
  a `style.test.ts` guard on the stylesheet's `pointer-events` layering.
- CI (`.github/workflows/pr.yml`) picks the jobs to run from the paths a change
  touches: a `web/` change builds and tests the browser app, an `ios/` change
  builds and tests the native app, and a workflow change runs both. A final
  `gate` job aggregates the results so branch protection has one unambiguous
  required check. A separate workflow (`.github/workflows/label-platforms.yml`)
  adds a `web` and/or `ios` label to the PR.
- Deployment (`.github/workflows/deploy.yml`) publishes `web/dist/` to the
  `gh-pages` branch root on pushes to `main`; GitHub Pages serves that branch.
- PR previews (`.github/workflows/preview.yml`) publish each PR commit to
  `preview/<branch>/` on the same `gh-pages` branch (so main and previews coexist
  on one Pages site) and comment the URL on the PR. Only `web/` changes produce
  a preview, since a native build has nothing to publish.

## 14. Known limitations

- All state lives in memory and is autosaved to `localStorage`; a cleared cache
  or a different browser loses the workspace (GPX export is the portable copy).
- Elevation stats and the profile depend on DEM availability and are only as
  accurate as the ~30 m sampling.
- Trail/peak snapping depends on the MapTiler tilesets being reachable and
  complete; when they are not, drawing and waypoints degrade to raw placement.
  A snap whose every tile fails is now reported in the service banner rather
  than failing silently.
- Snapping can only use geometry the tilesets publish, so it is bounded by their
  deepest zoom: `outdoor` stops at z14 and the planet tileset at z15, beyond which
  the endpoints return 400. A snap is therefore never more precise than the best
  geometry the tilesets serve, which leaves a residual offset of a few metres
  from the real trail.
- Following a trail uses only the geometry in the decoded tiles. If a trail
  leaves the read area between two clicks, or the shortest chain along it is more
  than `TRAIL_MAX_DETOUR` times the straight line, the route falls back to a
  straight segment. On a recorded 12.5 km hike roughly one leg in eight still
  falls back, mostly where the trail runs along a ridge with no mapped path.
- Dragging a point and importing a GPX never re-snap, so those coordinates stay
  exactly where the user put them or where the file recorded them.
- Very large "keep every point" imports still create one DOM marker per point
  and can be slow.
- GPX metadata (time, heart rate, etc.) beyond coordinates/elevation/name is not
  preserved.
- **"My location" is a one-shot lookup, not tracking.** There is no
  `watchPosition`, so the dot does not follow you while walking, and accuracy
  comes from the device (tens of metres on a phone with GPS, often hundreds of
  metres or a timeout on a desktop). It also needs a secure context, so it is
  unavailable when the app is served over plain HTTP from a non-localhost host.
