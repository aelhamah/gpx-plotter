# Features

Everything currently implemented in the GPX Route Plotter, grouped by area.

## Map and terrain

- **Outdoor basemap** rendered by MapLibre GL JS, served by MapTiler.
- **Satellite basemap** toggle. The camera (center/zoom/bearing/pitch) is
  preserved across the style swap, and all custom layers + 3D terrain are
  re-applied after the new style loads.
- **3D terrain** toggle using MapTiler Terrain-RGB with a 1.15× exaggeration,
  plus ⌘/Ctrl-drag to tilt and rotate the camera.
- **Relief hillshade** toggle for a soft shaded-relief overlay.
- **Slope-angle shading**: the terrain is colorized into avalanche bands
  (`<20°` green, `20–30°` yellow, `30–35°` orange, `35–40°` red, `40–45°`
  purple, `45°+` near-black), with an on-map legend. Implemented as a custom
  `slope://` raster protocol so shading stays aligned while panning, tilting,
  and rotating.
- **Fit to view** control that frames all routes and waypoints.

## Search

- **Map search bar** pinned to the top of the map for finding peaks,
  towns/municipalities, mountain ranges, trails, and trailheads.
- Backed by the **MapTiler Geocoding API** (the same account/key as the
  basemaps), filtered to `municipality`, `place`, `locality`, `poi`,
  `major_landform`, and `address` place types so results stay relevant to
  hiking. MapTiler indexes named trails, paths, and backcountry roads under
  `address`, so that type is what makes names like "Boneyard Trail" or
  "Lead King Basin Road" searchable.
- **Trails and trailheads**: named ways whose name looks like a trail
  (contains "trail", "path", "loop", etc.) are badged **Trail** and frame the
  way's bounding box when picked; trailhead places (POIs such as "Kilpacker
  Trailhead") are badged **Trailhead**; other indexed ways are badged
  **Street**.
- **Type-ahead results** appear as you type (debounced). Pick with a click,
  the ↑/↓ arrow keys, or press Enter for the highlighted (first) match; Esc
  or clicking elsewhere closes the list.
- **Ranked by map position**: the current map center is sent to the API as a
  `proximity` bias, so nearby peaks/places rank higher than far-flung
  namesakes.
- **Peak detection**: genuine peaks are detected from the data
  (`natural=peak` / `peak` category) and labeled **Peak** rather than the
  generic "Point of interest", with their summit elevation shown next to the
  name ("Peak · 14,042 ft"), while their region is rebuilt from the
  county/state/country hierarchy ("Alamosa, Colorado, USA" instead of the
  shorter "Alamosa, United States").
- **Fit to location**: selecting a result frames the area — bounding-box fit
  for towns and ranges, a point zoom for peaks — and drops a temporary marker
  that is cleared by the next search or Esc.
- Degrades gracefully: blank queries, no matches, and network failures all
  show a quiet empty state instead of errors.

## Routes

- **Multiple routes**, each with a stable id, name, and color from a
  deterministic palette (colors wrap when routes outnumber colors).
- **Draw a route** by clicking the map. A floating draw bar shows the live point
  count, a **Finish** button (enabled at ≥ 2 points), and **Cancel**.
- **Trail snapping**: route points drawn within ~40 m of a mapped trail snap onto
  it. Trails come from the same `outdoor` tileset the basemap renders plus
  path-like `transportation` lines, so ordinary OSM paths that aren't part of a
  marked route still snap (e.g. Redneck Ridge and the Eagle Valley Trail).
- **Hover preview**: while drawing, a dashed line and a blue dot show where the
  next point will land (snapped to the trail) before you click.
- **Follows the trail**: when a point lands within ~15 m of a trail and the
  previous one is on it too, the trail's own vertices are inserted between them,
  so the route runs along the trail instead of cutting straight across.
- **New route** creates a route and drops straight into drawing.
- **Drag route points** to reshape a route; elevation is re-sampled after a drag.
- **Rename routes** from the sidebar or by double-clicking the route's map label.
- **Remove routes** from the route list.
- **Visibility toggle**: an eye button next to each route hides/shows it on the
  map (line, point markers, and label) without deleting it; hidden routes are
  dimmed in the list and skipped by "fit to view". The toggle persists with the
  workspace and exports still include hidden routes.
- **Merge routes**: combine two routes into one continuous route. Click the
  merge toolbar icon, then pick two routes — the trace runs from one free end,
  through the first route, across the joint (joined at the endpoints nearest
  each other, reversing routes as needed), and out along the second. If the two
  traces share a stretch of ground near the joint within ~10 m and are walking
  it in the same direction, the duplicated head is dropped so shared ground is
  covered once. The originals are kept; Esc cancels.
- **Select routes** to make one "active" for editing, stats, and the profile;
  the list shows a color swatch per route.

## Waypoints

- **Add waypoints** in a one-shot mode: click the toolbar icon, click the map,
  and a single waypoint is placed (the mode then exits).
- **Drag waypoints** to reposition them.
- **Rename waypoints** by double-clicking the marker or its label.
- **Delete** the selected waypoint with Delete or Backspace.
- **Elevation labels**: each waypoint label shows its name and terrain
  elevation, sampled from the DEM once and kept up to date.
- **Peak snapping**: a waypoint dropped within ~250 m of a mapped peak snaps to
  the summit, inheriting the peak's name and elevation from the planet tileset.
- **Waypoint count** section summarising how many waypoints exist.
- **Selection affordance**: the selected waypoint is highlighted with a border
  and an edit (✎) label; clicking empty map clears the selection.

## Persistence

- **Workspace autosave**: routes, waypoints, the map name, units, and the map
  view are saved to `localStorage` as you work, so refreshing the page restores
  your progress.
- **Clear**: a "Clear" button in the sidebar footer opens a confirmation dialog
  and wipes all routes, waypoints, saved data, the map name, and units.
- **GPX export** remains the portable way to keep a workspace on disk.

## Import

- **GPX tracks and routes**: reads `<trk>/<trkseg>/<trkpt>` and falls back to
  `<rte>/<rtept>`.
- **GPX waypoints** (`<wpt>`) with names and elevations.
- **Elevation preservation**: `<ele>` is parsed and kept; missing elevations are
  later filled from the terrain DEM.
- **Additive imports**: importing appends routes and waypoints to what is
  already loaded and frames the view on the newly imported content.
- **Large-file downsampling dialog**: files with more than 500 points in a route
  open a dialog before loading, offering a point budget with a live preview of
  the resulting point count and a "keep every point" option.
  - The **default budget scales with route distance** — roughly one point every
    15 m — so longer tracks keep proportionally more points.
  - Downsampling keeps the first and last point of each route and thins the
    middle while preserving the shape.
- **Stale elevation handling**: files previously exported by this app are
  detected (`creator="GPX Plotter"`) and their cached elevations are discarded so
  stats are recomputed from current terrain.

## Export

- **Export GPX** writes a GPX 1.1 document containing every route as a separate
  `<trk>` plus all waypoints as `<wpt>`, preserving elevations where known.
- The download filename is derived from the first route name.

## Statistics

- Per-route **distance, total gain, total loss, low, high, point count, and max
  slope**, shown in the sidebar.
- Stats are computed from the terrain **between vertices**: the route is
  resampled every ~30 m and each sample is filled from the DEM, so gain/loss and
  slope reflect the ground actually crossed.
- A **"Reading terrain…"** spinner indicates when DEM sampling is in progress.

## Elevation profile

- Interactive **canvas elevation chart** for the active route.
- Segments are colored by **slope band**, matching the map shading.
- **Distance/elevation axes** with automatic tick spacing.
- **Hover** snaps to the nearest sample, shows a distance/elevation readout,
  draws a dashed cursor, and highlights the corresponding trail on the map with
  a blue trace and a matching blue dot.
- Slightly translucent chart background so the map shows through, with darkened
  axis labels for readability.

## Units

- **Metric / Imperial** toggle.
- The default is chosen from the browser locale (imperial for `US`, metric
  otherwise).
- All distances, elevations, and the profile axis respect the selection.

## Editing and shortcuts

- **Document-level undo/redo** (bounded to 50 snapshots), covering every point,
  waypoint, rename, delete, and import.
- Keyboard shortcuts:

  | Shortcut | Action |
  | --- | --- |
  | Click map | Add a route point (drawing) or waypoint (waypoint mode) |
  | Enter | Finish the current drawing |
  | Esc | Cancel drawing / waypoint mode / route merge / the import dialog |
  | Delete / Backspace | Remove the selected point or waypoint |
  | ⌘/Ctrl-Z | Undo |
  | ⇧⌘/Ctrl-Z | Redo |
  | ⌘/Ctrl-drag | Tilt / rotate the camera |
  | Scroll | Zoom the map (or scroll the sidebar when hovering it) |

## Interface

- **Map name** field at the top of the sidebar names the whole document: it
  drives the browser-tab title, the exported `.gpx` filename, and the
  `<metadata><name>` written into the file (restored on re-import). Importing a
  GPX pre-fills it from the file's metadata name or filename.
- Translucent, blurred sidebar floating over a full-bleed map with click-through
  gaps.
- Icon toolbars with hover tooltips (including shortcut hints such as
  **Undo · ⌘Z**) and segmented button groups.
- Map controls (fit, terrain, satellite, relief, slope) stacked at the
  bottom-left; the slope legend at the bottom-right.
- Responsive layout tweaks for narrow/mobile viewports.

## Demo data and quality

- Sample tracks are bundled under `public/demos/` (also served at `/demos/…`):
  `Afternoon_Hike.gpx` (a ~13,000-point hike) and
  `The_Enchantments_Traverse.gpx`, both useful for exercising the downsampling
  flow.
- **139 unit tests** across 16 files covering geodesy, GPX parse/serialize, DEM
  decoding, units, colors, names, config, downsampling, drag thresholds,
  geocoding, route merging, workspace storage, the MVT tile decoder,
  trail/peak snapping, and trail-network routing.
- GitHub Actions workflows for CI (build + test) and GitHub Pages deployment.
