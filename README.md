# GPX Route Plotter

A small client-side GPX route editor built with TypeScript, Vite, MapLibre GL JS, and MapTiler.

## What it currently does

- Displays a MapTiler Outdoor basemap.
- Imports GPX tracks/routes in the browser.
- Draws a route by clicking on the map.
- Drags route points to edit them.
- Deletes selected points with Delete.
- Undo/redo.
- Calculates distance and imported elevation gain/loss/min/max.
- Toggles 3D terrain using MapTiler Terrain RGB.
- Exports a GPX 1.1 track.
- Requires no backend, database, or login.

## 1. Add your MapTiler API key

Copy `.env.example` to `.env.local` and set your browser/public MapTiler API key:

```bash
cp .env.example .env.local
```

```text
VITE_MAPTILER_API_KEY=your_browser_maptiler_key
```

`.env.local` is gitignored, so the key never gets committed.

Because this is a static site, the key is visible to users. That is expected. **Do not use a private/service token.** Protect the public key with HTTP-origin restrictions in MapTiler. For GitHub Pages, allow the origin for your published site, such as:

```text
https://YOUR-USERNAME.github.io
```

If you use a custom domain, allow that domain instead.

## 2. Run locally

```bash
npm install
npm run dev
```

Open the local URL printed by Vite.

## 3. Build

```bash
npm run build
```

The production site is generated in `dist/`.

## 4. Deploy to GitHub Pages

The easiest setup is:

1. Create a GitHub repository.
2. Push this project to the repository.
3. Add the GitHub Actions workflow below as `.github/workflows/deploy.yml`.
4. In GitHub, go to **Settings → Pages** and select **GitHub Actions** as the source.

```yaml
name: Deploy to GitHub Pages

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm

      - name: Install
        run: npm install

      - name: Build
        run: npm run build

      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: dist

  deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    needs: build
    steps:
      - name: Deploy
        id: deployment
        uses: actions/deploy-pages@v4
```

## Important API-key note

A frontend map key cannot be kept secret on a static site. The right approach is to use a public browser key and restrict it to your site's HTTP origin. See MapTiler's key-protection documentation:

https://docs.maptiler.com/guides/maps-apis/maps-platform/how-to-protect-your-map-key/

## Next features worth adding

- Elevation lookup for newly drawn points.
- Interactive elevation profile.
- Multiple tracks/routes.
- Waypoints.
- Route point insertion between existing points.
- Map style switcher (Outdoor / Topo / Satellite / Winter).
- GPX metadata preservation.
- Optional trail snapping/routing.
- Better mobile editing UX.
