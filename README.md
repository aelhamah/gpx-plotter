# GPX Route Plotter

A browser-based GPX editor: draw, import, inspect, and export hiking/running
routes on a 3D MapTiler terrain, with live distance, climb, and slope stats plus
an interactive elevation profile.

It is a purely static, client-side app — **no backend, database, or login**. The
whole app is a few TypeScript modules bundled by Vite and rendered by MapLibre.

- Full architecture: [`docs/architecture.md`](docs/architecture.md)
- Feature reference: [`docs/features.md`](docs/features.md)
- Contributing / dev workflow: [`docs/dev.md`](docs/dev.md)

## High-level architecture

```
┌───────────────────────────────────────────────────────────────────────┐
│ index.html  —  static shell (sidebar, map container, toolbars, dialogs)│
└───────────────────────────────────────────────────────────────────────┘
                    │ imports
                    ▼
┌───────────────────────────────────────────────────────────────────────┐
│ src/main.ts  —  the application hub                                    │
│  • map init + layers + terrain                                         │
│  • in-memory state (routes, waypoints, selection, history)             │
│  • all DOM wiring, markers, dialogs, profile chart                     │
└───────────────────────────────────────────────────────────────────────┘
        │            │           │            │           │
        ▼            ▼           ▼            ▼           ▼
   gpx.ts       geo.ts       dem.ts      simplify.ts   units.ts / colors.ts
   parse &      geodesy &    Terrain-RGB  downsample    formatting &
   serialize    profiles     sampling     large tracks  palette
```

**Data flow**

1. **Import** — `File.text()` → `parseGPX()` → (large files) the downsampling
   dialog → `downsamplePoints()` → appended to state.
2. **Edit** — map clicks and marker drags mutate `routes` / `waypoints`; each
   mutation snapshots prior state for undo/redo.
3. **Stats** — the active route is resampled with `routeProfilePoints()` every
   30 m, missing elevations are filled from MapTiler Terrain-RGB via
   `elevationAt()`, then `summarizeProfile()` produces gain/loss/low/high/max
   slope and the elevation profile is drawn to a `<canvas>`.
4. **Render** — MapLibre layers draw route lines, the profile hover trace, slope
   shading (via a custom `slope://` raster protocol), and hillshade; DOM
   `Marker`s render draggable route points, route labels, and waypoints.
5. **Export** — `exportGPX()` writes a multi-track/waypoint GPX 1.1 file and the
   browser downloads it.

**State & undo/redo** live in `main.ts` as plain module variables. `snapshot()`
deep-clones `{ routes, waypoints }`; `commitSnapshot()` pushes onto a bounded
history stack so ⌘/Ctrl-Z and ⇧⌘/Ctrl-Z replay whole documents.

## Third-party dependencies

Runtime:

- [MapLibre GL JS](https://maplibre.org/) — open-source WebGL map renderer (vector styles, terrain, custom protocols, markers).
- [MapTiler](https://www.maptiler.com/) — basemap styles (Outdoor/Satellite), Terrain-RGB DEM tiles, and hillshade data used through MapLibre. See the [MapTiler documentation](https://docs.maptiler.com/).

Build & dev:

- [Vite](https://vite.dev/) — dev server and production bundler.
- [TypeScript](https://www.typescriptlang.org/) — language and type checking.
- [Vitest](https://vitest.dev/) — unit test runner.
- [jsdom](https://github.com/jsdom/jsdom) — DOM environment for tests.
- [@types/geojson](https://www.npmjs.com/package/@types/geojson) — GeoJSON typings for the map layer code.

## Getting started

Add a **public** MapTiler key (browser keys are visible to users; restrict them
by HTTP origin):

```bash
cp .env.example .env.local
```

```text
VITE_MAPTILER_API_KEY=your_browser_maptiler_key
```

`.env.local` is gitignored, so the key is never committed.

```bash
npm install
npm run dev      # local dev server
npm run build    # type-check + production bundle in dist/
npm test         # Vitest unit tests
```

## Deployment

The app is static, so it deploys to any static host. This repository ships two
GitHub Actions workflows:

- `.github/workflows/pr.yml` — build + test on every push/PR.
- `.github/workflows/deploy.yml` — build and publish `dist/` to GitHub Pages on
  push to `main`.

Enable **Settings → Pages → Source: GitHub Actions**, and allow-list your Pages
origin on the MapTiler key.

See [`docs/dev.md`](docs/dev.md) for the full development guide.
