# Development guide

How to set up, run, test, and extend the GPX Route Plotter.

## Prerequisites

- Node.js 22 (matches CI and the deploy workflow).
- A **public** MapTiler API key with your local/dev origin allowed.

## Setup

```bash
npm install
cp .env.example .env.local     # then set VITE_MAPTILER_API_KEY
npm run dev                    # http://localhost:5173
```

`.env.local` is gitignored. Never commit a real key, and never use a
private/service token — the key ships to the browser by design. Protect it with
HTTP-origin restrictions in the MapTiler dashboard.

## Scripts

| Command | What it does |
| --- | --- |
| `npm run dev` | Vite dev server with HMR. |
| `npm run build` | `tsc -b` type-check, then `vite build` → `dist/`. |
| `npm run preview` | Serve the production build locally. |
| `npm test` | Run the Vitest suite once. |

There is no separate lint script; `tsc -b` (run as part of `build`) is the type
gate, and the test suite is the behavior gate. Run both before committing.

## Project conventions

- **Pure logic lives in small modules** (`geo.ts`, `gpx.ts`, `dem.ts`,
  `simplify.ts`, `units.ts`, `colors.ts`, `names.ts`) with no DOM or MapLibre
  dependencies where possible. This is deliberate: it keeps the code unit
  testable in jsdom without a real map.
- **`main.ts` is the hub** for anything stateful, DOM-related, or map-related.
  When adding a feature, prefer adding a pure helper to a module and keeping the
  wiring thin in `main.ts`.
- **Types are shared** from `gpx.ts` (`Route`, `RoutePoint`, `Waypoint`).
- **State changes are snapshotted** for undo/redo. Call `commitSnapshot()`
  immediately *before* mutating `routes` or `waypoints`, then re-render.
- **Rendering entry points**: `refreshRoutesLayer()` (lines + list + markers),
  `refreshMarkers()` (markers only), `updateUI()` (sidebar summary), and
  `refreshRouteStats()` (async DEM stats + profile chart).
- **Units**: never format numbers inline — go through `units.ts`.
- **No comments explaining the obvious.** Comments exist only for non-obvious
  behavior (see `dem.ts` / `simplify.ts`).

## Testing

Tests use **Vitest** with the **jsdom** environment and cover the pure modules:

```
tests/
  geo.test.ts        distances, slopes, summaries, resampling, chart math
  gpx.test.ts        parse (trk/rte/wpt, elevation) + export round-trips
  dem.test.ts        Terrain-RGB decoding, tile math, slope raster
  units.test.ts      metric/imperial formatting + defaults
  colors.test.ts     palette determinism/wrapping
  names.test.ts      fallback naming
  config.test.ts     URL assembly
  simplify.test.ts   downsampling + distance-based budget
```

Guidelines:

- Add a test whenever you add or change a pure function.
- Prefer small, deterministic cases; avoid network and real map rendering.
- DOM-heavy code in `main.ts` is exercised manually (see below) rather than in
  unit tests.

## Adding a feature (checklist)

1. **Model / math first.** Put reusable logic in a pure module and write a test.
2. **State.** If it needs new state, declare it at the top of `main.ts` and, if
   it affects the document, include it in `snapshot()`.
3. **Render.** Update the relevant `refresh*` function so the map/list stays in
   sync, and call `commitSnapshot()` before mutating.
4. **UI.** Add markup to `index.html` and styles to `style.css`; keep icon
   buttons wrapped in `.icon-button-wrap` so tooltips work.
5. **Empty states.** Update `updateUI()` / `fillRouteList()` for the empty case.
6. **Verify.** `npm run build && npm test`, then try it in the browser.

## Manual verification

Because the app is map- and DOM-heavy, some checks are manual:

- Import a small GPX and a large one (see `public/demos/Afternoon_Hike.gpx`) and
  confirm the downsample dialog, stats, and profile.
- Draw a route, drag points, add/move/rename/delete a waypoint, undo/redo.
- Toggle satellite, terrain, relief, and slope shading (watch for layer loss
  after style swaps).
- Check the profile hover trace and the blue dot on the map.

Automated browser probing is possible over the Chrome DevTools Protocol (headless
Chrome exposes `--remote-debugging-port`), which is handy for DOM assertions and
feeding files into the `<input type=file>` via `DOM.setFileInputFiles`. Note that
headless Chrome has **no WebGL**, so map rendering (terrain, rasters, slope
shading) cannot be verified there — use a real browser for visual checks.

## Gotchas

- **Style swaps drop custom layers.** Any time the map style is replaced
  (satellite toggle), re-add sources/layers and terrain on `style.load`. This is
  the single most common source of "my layer vanished" bugs.
- **Custom markers are DOM elements.** One is created per route point, so large
  imports are expensive — that is why the downsampling dialog exists.
- **`.hidden` ordering.** Utility/`.hidden` rules must not be overridden by later
  `display` rules on the same element; use a compound selector
  (`.modal-backdrop.hidden`) if needed.
- **`#map-status`** must stay in the DOM — `main.ts` writes status and error
  messages to it.
- **Async stats races.** `refreshRouteStats()` uses a `statsToken`; keep that
  pattern for any new async render path.
- **Antimeridian**: the route resampler wraps longitudes; be careful if you
  touch the Mercator helpers.

## Deployment

- CI (`.github/workflows/pr.yml`) builds and tests on pushes and PRs.
- Deploy (`.github/workflows/deploy.yml`) publishes `dist/` to GitHub Pages on
  push to `main`. Enable **Settings → Pages → Source: GitHub Actions**, and
  allow-list the Pages origin on your MapTiler key.
- `vite.config.ts` sets `base: './'` so assets resolve on project Pages sites.
