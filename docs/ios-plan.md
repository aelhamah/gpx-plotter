# iOS app plan

A native iPhone/iPad app for viewing and navigating the same GPX routes as the
web app in [`web/`](../web), with offline satellite imagery you control, Live
Activity guidance, and off-course alerts.

**Status:** M1 Core is complete and green (RouteKit, 115 XCTest cases, `swift test`
passing). Offline is implemented on our own tile cache rather than MapLibre's
pack API, and the corridor download works — see [§9](#9-offline) and the M5 row
in [§10.1](#101-actual-state). The M0 spike is code-complete and partially
verified; the one thing no simulator can settle is a real airplane-mode run on a
device.

---

## 1. The finding that shapes the decision

Apple shipped the app this project would otherwise be, first-party, and has kept
the APIs closed.

iOS 18 (September 2024) added to Apple Maps: topographic hiking maps with contour
lines, "Plan a Hike" custom routes with distance / elevation gain / elevation
profile / walking-time estimates, Out & Back and Close Loop, undo while drawing,
**turn-by-turn navigation on trails**, **download for offline use**, and Apple
Watch sync.

The complete set of additions in the **iOS 26.0 MapKit API diff** is
`MKAddress`, `MKAddressRepresentations`, `MKGeocodingRequest`,
`MKReverseGeocodingRequest`, and `MKMapItem.location` / `.address`. Nothing
rendering-, terrain-, or offline-related. Two OS releases, nothing opened.

So the durable wedge is what Apple does not do:

- **Arbitrary GPX import.** Apple's custom routes are drawn on their own map and
  locked to their network; they cannot take a Gaia, GPS Watch, or Strava file.
- **Slope-band hazard analysis** from a real DEM. Apple has contours, not a
  steepness overlay.
- **Peak / named-trail / trailhead search** with elevation.
- **Satellite offline you control**, rather than a black box.

Every one of those is engine-neutral or favours MapLibre. None of them need
MapKit.

## 2. Map engine: MapLibre Native, not MapKit

The deciding constraint is offline. **MapKit exposes no public tile API**, so
"offline satellite" forces a parallel stack regardless: your own
`MKTileOverlay`, your own disk cache, your own downloader, your own eviction.
Once that exists the satellite and offline map are *yours* — and you are still
paying MapKit's permanent constraints on top. That cost compounds annually.

The costs MapLibre Native imposes are paid once: a `UIViewRepresentable`
wrapper and your own map chrome.

| | MapKit | MapLibre Native |
| --- | --- | --- |
| Offline satellite | Build your own tile stack anyway | `MLNOfflineStorage` + `MLNShapeOfflineRegion`; no tile ceilings, no per-MAU pricing |
| Slope shading | Permanent `MKTileOverlay` reimplementation | Same math, one raster source |
| Hillshade / relief | Not a MapKit concept, ever | `MLNHillshadeStyleLayer`, built in |
| Style drift | Apple restyles Apple Maps every 1–2 releases; you cannot pin it | You own the style JSON |
| Peak / trail search | `MKLocalSearch` is address-only, permanently | Same `geocode.ts` port |
| Navigation, Live Activity, off-course | **Identical** — ActivityKit and CLLocationManager are map-agnostic | Identical |
| Per-coordinate elevation | No public API | No public API — both need the Terrain-RGB decode below |
| Field-mode battery saving | Cannot reduce Apple's basemap detail | Swap to a stripped style when not route-following |
| Native extras | Look Around, first-party Apple nav UI | — |
| Globe | — | Not in Native (it is a GL JS feature) |

Note the elevation row: MapKit gives you no way to ask for the elevation of a
coordinate, so the Terrain-RGB decode in `web/src/dem.ts` has to be ported
either way. "Use Apple's DEM" is not actually available to a third-party app.

**What we give up:** Look Around, first-party Apple navigation UI, and a
`UIViewRepresentable` instead of SwiftUI's `Map`. Acceptable for a viewer and
navigator, and recoverable — see §4.

## 3. Scope

**In:** GPX import, the web app's map appearance, statistics and elevation
profile, search, navigation with Live Activity, off-course alerts, offline
satellite.

**Out:** all route editing. No drawing, no vertex dragging, no merge, no undo
stack, and no GPX export UI. This removes three TypeScript modules that exist
*only* to support snapping and drawing, plus most of `main.ts`:

| Dropped | Lines | Why it exists |
| --- | --- | --- |
| `web/src/mvt.ts` | 239 | MVT protobuf decoder, feeds trail snapping |
| `web/src/trailGraph.ts` | 215 | Dijkstra along trail polylines, snapping only |
| `web/src/snapSources.ts` | 210 | fetches trail/peak vector tiles for snapping |
| `web/src/snapTiles.ts` | 141 | picks the zoom and tile set a snap query needs |
| `web/tests/fixtures/haloridge14ers.gpx` | 12.5 km | recorded hike fixture, snapping tests only |
| `web/src/merge.ts` | 90 | merging two routes |
| `web/src/drag.ts` | 3 | vertex drag threshold |
| `web/src/main.ts` edit machinery | ~700 of 1797 | draw / drag / merge / undo / dialogs / shortcuts |

That also drops the 78 tests in the six snapping suites (`mvt`, `snap`,
`snapTiles`, `snapSources`, `trailGraph`, `snapHaloRidge`) of the 266 web tests,
which are not ported. `snap.ts` is partly kept — see the ported list below.

Editing can be added later without a rewrite, because `RouteKit` is pure.

## 4. Architecture

```
ios/
├── RouteKit/                      local SPM package — no UIKit, no MapKit
│   ├── Sources/RouteKit/
│   │   ├── Model/     Route, RoutePoint, Waypoint, Workspace
│   │   ├── Geo/       Haversine, Profile, Mercator, TileMath
│   │   ├── GPX/       GPXParser (streaming XMLParser), GPXWriter
│   │   ├── Terrain/   TerrainRGB, TerrainTileStore, SlopeBands
│   │   ├── Progress/  RouteProgress, ProjectionGeometry, OffCourseDetector
│   │   ├── Track/     Downsampler
│   │   ├── Search/    GeocodingClient, SearchResult
│   │   └── Net/       TileCache, HTTPClient
│   └── Tests/         XCTest — port of ~120 web cases
└── App/
    ├── GPXNav/                    SwiftUI app target
    │   ├── Map/                   MapView (UIViewRepresentable), layers, overlays
    │   ├── Nav/                   NavigationSession, LocationTracker, LiveActivity
    │   ├── Storage/               WorkspaceStore
    │   └── Features/              Library, Viewer, Navigate, Settings
    └── GPXNavWidgets/             Live Activity + Dynamic Island
```

`RouteKit` is a direct port of the pure web modules, so `summarizeProfile`,
`routeProfilePoints`, `decodeElevations`, `nearestOnLine` and the GPX round-trips
stay behaviourally identical and testable without a simulator. Every tunable is
carried over verbatim:

- 30 m stats/profile resample · 15 m default import downsample spacing
- 40 m / 250 m snap radii · 1.15 terrain exaggeration
- 0.5 hillshade exaggeration · 6-result geocode limit
- Haversine on a 6371008.8 m mean radius

### MVC, and how it maps onto SwiftUI

The app keeps a **Model–View–Controller** split. SwiftUI does not have
UIKit's view controllers, so the mapping is:

| Role | What it is here | Rule |
| --- | --- | --- |
| Model | `RouteKit`, plus `WorkspaceStore`, `RouteAnalysis`, `OfflinePackManager`, `LocationController` | Holds state and logic. No view types, no MapLibre types. `WorkspaceStore` and friends are observable so views update, but they are the model, not a view-model layer bolted on top. |
| View | The SwiftUI structs in `Features/`, plus `RouteProfileChart` and `MapView` as a leaf | Declarative layout only. A view formats and forwards intent; it does not compute route statistics, parse GPX, or talk to MapLibre. |
| Controller | `MapView.Coordinator` (the `MLNMapViewDelegate`), `SlopeServerManager`, `StyleBuilder`, and the per-screen controllers behind each tab | Owns the imperative engine and mediates between model and view. Anything that talks to MapLibre or a socket is a controller. |

Two consequences worth writing down, because they are easy to lose:

- Business logic does not move into views when a screen grows. The first cut of
  the elevation profile computed cumulative distance and thinning inside the
  chart view; that had to move into `RouteAnalysis` once the stats were derived
  from the same samples. If a view starts doing arithmetic over route points, it
  belongs in the model.
- `MapLibre` imports stay inside `Map/`. A view that needs the engine talks to a
  controller, which is why `MapView` is a `UIViewRepresentable` with a
  coordinator rather than MapLibre calls sprinkled through `Features/`.

**No `MapEngine` protocol.** With the engine decided, an abstraction over one
implementation is speculative. Instead: all logic lives in `RouteKit` with zero
map types, and MapLibre-specific code is confined to `ios/App/GPXNav/Map/`. If
CarPlay or Look Around ever become hard requirements, one directory is
rewritten.

### Ported modules

| Web source | Tests | Notes |
| --- | --- | --- |
| `web/src/geo.ts` | 17 | haversine, resampling, `summarizeProfile`, Mercator |
| `web/src/geocode.ts` | 19 | MapTiler search; Peak/Trail/Trailhead badges |
| `web/src/gpx.ts` | 15 | streaming `XMLParser`; writer kept, it is ~30 lines |
| `web/src/locate.ts` | 18 | accuracy halo, zoom-for-accuracy |
| `web/src/simplify.ts` | 9 | import-time downsampling |
| `web/src/storage.ts` | 9 | versioned workspace JSON |
| `web/src/dem.ts` | 7 | Terrain-RGB decode, bilinear sample, slope bands |
| `web/src/units.ts`, `colors.ts`, `names.ts` | 14 | |
| `web/src/snap.ts` (reduced) | ~6 | `nearestOnLine` only, for progress and off-course |
| new | — | `RouteProgress`, `OffCourseDetector`, `TileMath`, `TileCache` |

## 5. Stack

- **iOS 17.0** deployment target — `CLBackgroundActivitySession`,
  `Button(intent:)` in Live Activities, `@Observable`.
- Swift 6, SwiftUI. Expect `@preconcurrency import MapLibre`; the Obj-C
  framework is not Swift 6 audited.
- MapLibre Native via SPM (`maplibre/maplibre-gl-native-distribution`), wrapped
  once in a `UIViewRepresentable`.
- `TabView`: **Library** (route list, offline badges) and **Settings**; push
  **RouteDetail**; `.fullScreenCover` for **Navigation**.
- Info.plist: `NSSupportsLiveActivities`, `NSSupportsLiveActivitiesFrequentUpdates`,
  `UIBackgroundModes: [location]`, `NSLocationWhenInUseUsageDescription`,
  `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSAllowsLocalNetworking`
  (for the slope server, §6).

### 5.1 MapTiler key restrictions (corrections)

Two assumptions in the original plan were wrong, both found by measurement
during M0.

**1. "Restrict it by bundle ID" is not a MapTiler feature.** MapTiler offers two
protection methods, and neither is bundle-ID based:

| Method | Matches on | Usable from a native app? |
| --- | --- | --- |
| Allowed HTTP origins | `Origin` / `Referer` | **No** |
| Allowed user-agent header | `User-Agent` | **Yes** |

A native app can never satisfy a referrer allowlist. `NSURLSession` sends
neither `Origin` nor `Referer` for tile requests — verified on device, the
complete header set is `Host`, `Accept`, `Accept-Language`, `Connection`,
`Accept-Encoding`, `User-Agent`. MapTiler answers `403 Key usage restricted`,
and their docs confirm a request with no referrer is "treated as unknown and
will be rejected if any origin is specified". `Origin` is also a
[forbidden header name](https://fetch.spec.whatwg.org/#forbidden-header-name) in
`URLSession`, so it cannot be injected as a workaround.

**Both protections can live on one key.** Measured, not assumed: with the same
key configured for two allowed origins *and* the allowlisted user-agent, the
style, satellite style, Terrain-RGB tile, and geocoding endpoints all return 200
for web-origin requests and for the native `User-Agent` alike. The methods are
independent, not mutually exclusive.

| Client | Protection method | Allowlist value |
| --- | --- | --- |
| Web (dev + Pages) | Allowed HTTP origins | `http://localhost:5173`, `https://aelhamah.github.io` |
| iOS | Allowed user-agent header | `GPXNav (iOS; com.example.GPXNav)` |

The web app cannot use the user-agent method even in principle:
`User-Agent` is forbidden in `fetch`/XHR, so a browser silently drops it. It
still needs the origin allowlist; the iOS build needs the user-agent one.

**2. The allowlisted user-agent must not contain the version.** MapTiler may
match the whole header rather than a substring; if it does, a version bump
silently breaks the key *at release time*. So the app sends the bare token
`GPXNav (iOS; <bundle id>)` as `User-Agent` and puts build detail in a separate
`X-GPXNav-Version` header, which the allowlist never has to know about. The
allowlisted value is then correct now and after every future release. This is
enforced by `MapNetworkIdentity`, applied before the first `MLNMapView` is
created because `NSURLSession` copies its configuration at init.

Do **not** use MapTiler's `?` placeholder for "allow unknown origins" — it
reopens the key to everything, which is strictly worse than user-agent matching
for a native app.

### 5.2 Three MapLibre Native constraints found during M0

These were not in the original plan and change how §6 must be written:

1. **There is no 3D terrain API in the ObjC headers.** Neither `MLNStyle` nor
   `MLNMapView` exposes a `terrain` property, and there is no `MLNStyleTerrain`
   class. 3D terrain has to be authored into the **style JSON**; the "ease pitch
   to 55°" behaviour is unaffected, but `exaggeration: 1.15` cannot be set
   imperatively as §6 implies.
2. **`MLNRasterDEMSource` documents support for the Mapbox Terrain-RGB encoding
   only.** This narrows §10 risk 1 usefully: MapTiler's `terrain-rgb-v2` is that
   exact encoding, so relief *should* work. It is still unverified. It also means
   Terrarium-encoded sources (including MapLibre's public demo tileset) cannot
   drive a native hillshade layer — our own loopback decoder in RouteKit reads
   those fine, so slope shading and relief have different requirements.
3. **No `addProtocol`, confirmed.** There is also no way to observe or supply tile
   data through `MLNMapViewDelegate`, so the loopback `NWListener` in §6 is the
   only route. `MLNNetworkConfiguration.sharedManager.sessionConfiguration` is
   the supported hook for custom tile-request headers.

## 6. Viewer

MapTiler `outdoor-v2` base, style JSON assembled at runtime from the URLs in
`web/src/config.ts`, plus the layer stack from `main.ts:addDataLayers()`:

- `route-casing` — white, width 8, opacity 0.88
- `route-line` — width 4, per-route colour from the palette
- `route-points` — **circle style layers, not annotations**, so they stay glued
  under pitch and terrain (same reasoning as web commit `89704c3`)
- `location-accuracy` / `location-halo` / `location-dot`

Toggles: satellite (`satellite-v4`), 3D terrain, relief, slope.

3D terrain needs correcting: there is no imperative terrain API on Native (§5.2),
so the `raster-dem` source, `"terrain": {"source": …, "exaggeration": 1.15}`
block, and the raster layer all have to be written into the **style JSON** we
assemble at runtime. The camera side is ordinary — ease pitch to 55° is just
`MLNMapCamera`.

Slope shading is off until the M0 spike proves it works, and on the keyless demo
basemap it *cannot* work: the loopback server needs a DEM, and MapLibre's public
tileset serves Terrarium terrain, which `MLNRasterDEMSource` does not decode
(our own RouteKit decoder reads Terrarium fine, so only the native hillshade path
is affected).

**Hillshade is nearly free.** `MLNHillshadeStyleLayer` is built in and reads the
same `terrain` source — about five lines. On MapKit this was a whole hand-rolled
`MKTileOverlay` pipeline to maintain forever. A concrete MapLibre win.

**Profile chart** via Swift Charts, replacing the ~240-line canvas: per-segment
`LineMark(xStart:xEnd:yStart:yEnd:)` inside a `Chart` plot, foreground-styled
with the exact `slopeBandColorHex` colours, translucent `AreaMark` fill at 0.22
alpha to match. A `RuleMark` selection drives the profile-trace overlay. The
six-band slope legend is unchanged.

**Search** is a direct port of `geocode.ts`: debounced, six results, `proximity`
= current map centre rounded to five decimals, same `Peak` / `Trailhead` /
`Trail` / `Street` badges.

### The one real technical risk

The web app generates slope rasters through a custom protocol
(`main.ts:addProtocol('slope', …)`). **MapLibre Native iOS has no `addProtocol`
equivalent** — `MLNMapViewDelegate`'s tile callback is observational only, it
cannot supply data. Two viable designs:

- **Loopback HTTP (preferred, and what shipped).** An `NWListener` on
  `127.0.0.1`; the style points the `slope` raster source at
  `http://127.0.0.1:<port>/slope/{z}/{x}/{y}.png`. Mirrors `addProtocol` almost
  one-to-one. Needs `NSAllowsLocalNetworking`.
- **`MLNOfflineStorage.preloadData(_:for:…)`.** Compute the PNG and insert it
  under the exact URL the style requests. Clean and fully offline, but the app
  has to drive on-demand generation.

The loopback listener turned out to be worth more than slope shading. Because
the app is already assembling its own style, it repoints **every** tile source —
basemap, labels, contours, satellite rasters, and the DEM — at the same listener,
which is what makes offline work at all (§9). One mechanism serves slope rasters,
the style, the tile cache, and the offline download.

Also unverified: the style spec's support matrix marks `raster-dem` **custom**
encodings as unsupported on Native iOS ([#2783]). MapTiler `terrain-rgb-v2` uses
the *Mapbox* encoding (supported since 6.0.0), so it should work — but this is
the first thing the M0 spike checks, because if it fails we lose both 3D terrain
and hillshade.

## 7. App structure and screen layout

Added after a first pass at the viewer, from using it. The web app's layout
cannot be carried across literally: a phone in the hand has no room for a
sidebar, a profile canvas *and* a map at once.

### Bottom bar: Create, Navigate, Settings

Three tabs, replacing the current Library / Settings pair.

| Tab | What it is | Milestone |
| --- | --- | --- |
| **Create** | Search, pick waypoints, draw a route. Exports a GPX into the library when finished. | M2 for search and the drawing surface, M3 for export. |
| **Navigate** | Replaces the Library tab for now and behaves the same way: a list of maps, titled **Maps**, opening the full-screen viewer. Becomes live navigation in M3. | M2 for the list, M3 for guidance. |
| **Settings** | Basemap, terrain, units, data. As today. | Done. |

**Maps list.** The list is titled "Maps" rather than "Routes" or "Library": a
map is what the user is choosing, and the same list will hold routes that arrive
from a GPX export as well as ones that arrive from an import. It lives in the
Navigate tab until navigation needs the slot.

### The map is full screen

The map fills the display. The stats bar, profile, and offline row are no longer
siblings of the map in a `VStack`; they are an overlay panel over the bottom of
it, so panning the map is never fighting a layout that gives the map half the
screen. This is the single biggest change from the M0/M1 layout and it is what
makes the profile-trace interaction (§ below) possible.

### A collapsible bottom panel

**Decision: a draggable sheet with detents.** The map's figures live in a sheet
over the map rather than in a `VStack` beside it.

The sheet has two detents: collapsed it is **just the stats row**, expanded it
carries the stats, the profile, and the offline row. It reads its own height to
decide which, because a sheet's content does not otherwise know which detent it
is in — a fixed-height profile in the short detent is what clipped the stats row
when this was first built.

Dragging the sheet away entirely leaves the map full-bleed with the stats, which
is the state the map is really used in. `presentationBackgroundInteraction`
keeps the map pannable behind the sheet.

### Profile scrubbing and the map trace

Dragging along the elevation profile traces the position onto the map, the way
the web app's `profile-trace` layer does. The plan already called for this — "a
`RuleMark` selection drives the profile-trace overlay" — and it becomes much more
usable once the profile is an overlay rather than a sibling of the map.

- A `RuleMark` at the scrubbed distance, plus a readout of distance, elevation,
  and grade at that point.
- The map draws a `profile-trace` line for the portion of the route already
  covered, in the web app's `TRACE_COLOR` (`#0ea5e9`).
- `RouteProfile.index(nearestTo:)` already does the lookup, so the trace is a
  slice of the same resampled profile the chart and the stats use. The rule that
  keeps those three agreeing — one profile, three views — applies here too.

### Other fixes

- **The profile overlapped its axes.** The chart filled its whole frame, so the
  x-axis labels and the area fill collided with the bottom edge. The plot now has
  its own padding inside the frame.
- **One location button, and it points north.** There were two: a disabled
  *Navigate* toolbar item and a floating locate button. The toolbar one is gone
  — Navigate is a tab now. Tapping the remaining button recentres **and** rotates
  the map to the current heading, then tapping again snaps back to north, the way
  a compass button behaves. `MLNMapCamera` calls the rotation `heading`, not
  `direction`.
- **The title bar is slightly translucent**, so the map reads as continuing under
  the navigation bar rather than stopping at it. The map ignores *all* safe
  areas for this to have anything to show through; the search control sits below
  the bar to compensate.
- **Fix the download.** See §9 — this is not a UI fix, it needs the decision
  recorded there before any button is enabled again.

### Already satisfied

- **Multiple routes and waypoints in one GPX.** `GPXParser` returns every
  `<trk>`/`<rte>` as a route and every `<wpt>` as a waypoint, and
  `WorkspaceStore.importGPX` appends all of them. Verified with one file
  containing two tracks and one route plus two waypoints: three routes and both
  waypoints come in, each with its own id and palette colour.

## 8. Navigation

No turn-by-turn and no routing engine: `MKDirections` routes on Apple's road
graph and produces nothing useful above treeline. Guidance is trail-following,
and it is pure geometry — the highest-value part of the feature.

Precompute the 30 m profile and cumulative distances once when navigation
starts. Every tick is then a binary search: no DEM calls, no network.

State: distance along, remaining, current elevation, grade ahead (200 m
lookahead), nearest waypoint name, distance off route.

### Off-course detection

- Project the fix onto the polyline (`nearestOnLine`, from `snap.ts`).
- Gate on `horizontalAccuracy < 30 m` **and** `speed > 0.5 m/s` — this kills
  standing-start GPS wander, the main false-positive source.
- **Enter** off-course above 40 m sustained for 8 s; **clear** below 25 m
  sustained for 5 s. The gap is deliberate hysteresis.
- Ignore the first 15 s after start, while the fix settles.
- Fire a `.timeSensitive` local notification, flip the Live Activity state, and
  optionally speak a cue via `AVSpeechSynthesizer`. Avoid `.criticalAlert` — it
  requires an Apple entitlement.
- The distance-to-route readout is always visible in the nav bar, so a marginal
  deviation reads as a quiet number rather than an alarm. Offer a "back to
  route" action when off course.

### Live Activity

```swift
struct HikeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var distanceAlong: Double
        var remaining: Double
        var currentElevation: Double?
        var gradeAheadPercent: Double?
        var nextWaypointName: String?
        var isOffCourse: Bool
        var offCourseMeters: Double
    }
    var routeName: String
    var totalDistance: Double
    var startedAt: Date
}
```

Lock Screen: remaining distance, progress bar, grade chip, off-course banner.
Dynamic Island compact / minimal / expanded, with Pause and End via
`Button(intent:)` and a `LiveActivityIntent`. Updates at roughly 1 Hz, hence
`NSSupportsLiveActivitiesFrequentUpdates`.

Background location via `CLBackgroundActivitySession` (iOS 17+),
`allowsBackgroundLocationUpdates`, and `UIBackgroundModes: [location]`.

## 9. Offline

**Implemented, on our own tile cache rather than `MLNOfflineStorage`.** The
corridor download works: it fetches every tile the route's corridor crosses, for
every tile set the loaded style needs, and the map draws from disk with the
network gone. What follows is the evidence for dropping MapLibre's pack API, the
mechanism that replaced it, and the one thing still outstanding.

### Why not `MLNOfflineStorage`

Packs do not work on MapLibre Native 6.31.0. `addPack(for:withContext:)`
succeeds — the completion handler returns `error=nil` and the pack appears in
`storage.packs` — and then the pack never leaves `MLNOfflinePackStateInactive`,
`countOfResourcesExpected` and `maximumResourcesExpected` both stay `0`, and no
TileJSON or tile request is ever made. Causes ruled out by changing one variable
at a time:

| Style | Region | Pack state | Expected resources |
| --- | --- | --- | --- |
| MapTiler `outdoor-v2` (TileJSON `url` sources) | `MLNShapeOfflineRegion` | `Unknown` | 0 |
| MapLibre demotiles (inline `tiles`) | `MLNShapeOfflineRegion` | `Inactive` | 0 |
| MapTiler style rewritten to inline `tiles` | `MLNShapeOfflineRegion` | `Inactive` | 0 |
| MapTiler style rewritten to inline `tiles` | `MLNTilePyramidOfflineRegion` | `Inactive` | 0 |

The region is not the problem: the corridor ring is a valid 50-point polygon
over the right bounding box. It is not the zoom range either — z0–5 and z12–16
behave identically. So it is neither the TileJSON-only style, nor the region
shape, nor the requested zooms. `countOfResourcesExpected` is documented as a
*lower bound* that grows as a download progresses, so a `0` there is a statement
that MapLibre enumerated nothing at all.

Retry-on-a-newer-release was the cheap first option and was not taken: the app
already had to build its own style to inject the 3D terrain block, and once it
does, a locally-built style and a hand-rolled tile cache are the same amount of
machinery. The tile-fetching half is the part `MLNOfflineStorage` was going to
do for us.

### The mechanism: every tile passes through disk

`StyleBuilder` resolves each source's TileJSON, learns MapTiler's own
`{z}/{x}/{y}` template, and repoints the style at the loopback server:

```
/tiles/{source}/{z}/{x}/{y}.{ext}   →  TileCache  →  MapTiler on a miss
```

Three things follow from that, and all three are why offline works:

- **The cache is the offline store.** A tile on disk *is* a tile the map can
  draw, because the style asks the loopback for it and the loopback answers from
  disk without touching the network. There is no second mechanism and no
  "activate pack" step.
- **Browsing warms the cache.** Every tile the map displays passes through it on
  the way in, so an area you have already looked at is already offline. The
  corridor download is a bulk prefetch of the rest, not the only way to get
  anything offline.
- **The DEM goes through it too**, as `raster-dem` source `terrain`, so relief,
  3D terrain, and the slope generator all read the same cached elevation. Slope
  rasters are decoded from those bytes rather than re-fetched, which is why they
  work offline as well.

**The source name is part of the tile's identity, and it has to be.** This was a
real bug, not a hypothetical. A style's sources are different payloads at the
same `z/x/y` — `outdoor` is the basemap geometry, `contours` the elevation lines,
`maptiler_planet` the labels, `terrain` the DEM — so a cache keyed by
coordinates alone answers a `contours` request with `outdoor`'s bytes, and a
corridor prefetch that believed it had fetched all four sources had fetched one
and stored it four times over. `TileCacheKey` in RouteKit owns the identity
(source, coordinates, format) and everything derived from it, with the round trip
through the loopback path under test.

Raster sources are cached too, not only vector ones: the satellite basemap is a
`jpg` tileset, and an offline map holding the labels but not the imagery under
them would be a map of nowhere. The list of sources to fetch is read from the
loaded style rather than hardcoded, so switching basemaps changes what a
download covers.

**The download is not restricted to the basemap either.** Elevation is fetched
across z12–z14, not only at z14, because MapLibre asks a `raster-dem` source
for a tile at the *camera's* zoom — a corridor that covered the basemap at three
zooms but elevation at one would lose its hillshade and 3D terrain at the other
two.

### The rest of the design

Offer a corridor download on import: the route polyline plus roughly a 1 km
buffer.

**The zoom range is z12–z14, not z12–z16.** MapTiler's `outdoor-v2` style tops
out at z14 (`outdoor` z5–14, `contours` z9–14), so z15–z16 would only ever
produce empty tiles. `AppConfig.offlineZoomRange` is capped accordingly. The
satellite raster goes to z22, so nothing caps it, but nothing needs it to.

The plan originally said to test each tile centre against distance-to-route. As
written that selects **nothing at low zoom**, because a z12 tile is ~9.8 km across
while the buffer is ~1 km, so every tile centre falls outside the corridor. The
implemented rule keeps the intent and adds the tile's own half-diagonal to the
tolerance, which keeps every tile the corridor actually crosses and still drops
the inside-corner tiles a bounding rectangle would sweep in. See §9.1.

### The size estimate is measured, and the plan's figure was wrong

The plan says "roughly 100–200 tiles / 8–15 MB" for a 10 km route. The tile count
is right; the byte figure came from assuming satellite rasters, and it does not
describe what is actually downloaded. Measured over the 3.4 mi Maroon Bells loop
at z12–z14, 68 tiles, **4.4 MB**, and the four tile sets are nowhere near the
same size:

| Source | z12 | z13 | z14 |
| --- | --- | --- | --- |
| `outdoor` (pbf) | 4.6 KB | 2.5 KB | 1.2 KB |
| `maptiler_planet` (pbf, labels) | 9.2 KB | 10.6 KB | 7.2 KB |
| `contours` (pbf) | 123 KB | 182 KB | 74 KB |
| `terrain` (webp DEM) | 210 KB | 138 KB | 86 KB |
| `satellite` (jpg, satellite basemap only) | 65 KB | 72 KB | 74 KB |

So the estimate is **per source**, from `TileSourceSize`, and it is the reason
the earlier flat per-format table was wrong in both directions: it promised
5× more than the satellite tiles need and 5× less than the DEM does. Contour
lines dominate an outdoor download, which is not obvious until it is measured.

**Still outstanding:** confirm MapTiler's terms permit offline tile caching in a
distributed app. That is a licensing question, not an engineering one, and it can
invalidate the approach. It is the one item from this section that code cannot
settle.

## 10. Milestones

| | Scope | Gate |
| --- | --- | --- |
| **M0 Spike** | Xcode project + SPM, MapTiler style renders, `raster-dem` Terrain-RGB confirmed, loopback slope raster visible, offline pack survives airplane mode | **Go/no-go.** Slope shading is the first thing to cut if the loopback server misbehaves; if `raster-dem` fails, 3D terrain and hillshade both go |
| **M1 Core** | `RouteKit` + ~120 tests, GPX import, stats, Swift Charts profile | Import a GPX and see real numbers |
| **M2 Viewer** | Style builder, full layer stack, all toggles, waypoints, search, fit, locate, full-screen map, collapsible panel, profile scrubbing with map trace, Create/Navigate/Settings tabs | Visually matches the web app, in one hand |
| **M3 Navigate** | `NavigationSession`, progress, off-course, nav UI, background location, route drawing + GPX export from Create | Hike a real trail with the phone locked |
| **M4 Live Activity** | Widget extension, Dynamic Island | Glanceable from the lock screen |
| **M5 Offline** | Corridor prefetch, download manager, storage screen | Full hike in airplane mode |

#### 10.1 Actual state

**M1 Core — done, gate met.** `swift test` in `ios/RouteKit`: **115 tests, 0
failures.** The gate is "import a GPX and see real numbers", and that now works
end to end: import through the document picker, the numbers come from the same
RouteKit code the web app uses, and they survive a relaunch.

| Gate item | State |
| --- | --- |
| `RouteKit` + tests | **Done.** 115 tests, 0 failures. The plan said ~120; the port covers the modules this app uses, and 27 of the web tests belong to the dropped editing modules (§3). The tile cache and its key are part of RouteKit for a reason — the offline guarantee is only worth having if something can test it, and `swift test` runs in CI without a simulator. |
| GPX import | **Done.** `fileImporter` filtered to `.gpx`, security-scoped read, `RouteKit.parseGPX`. Verified with the repo's own demos: *The Enchantments Traverse* (7,153 pts → 18.49 mi, 8,080 ft ascent, 7,838 ft high) and *Afternoon Hike* (13,360 pts → 4.42 mi, 14,079 ft high). Route ids are reassigned on import and colored from the web app's `routeColorForId`. |
| Stats | **Done.** Distance/ascent/descent/high from `RouteKit`, formatted through `Units`, switching with the unit picker. A GPX with no `<ele>` shows `—` rather than zeros. |
| Swift Charts profile | **Done.** Elevation against distance along, with the y-domain padded by 8% of the range rather than anchored at zero, matching `profileData` in `web/src/main.ts`. |

Three defects found while wiring the UI, all fixed:

- The plist the app actually loads is the one xcodegen regenerates, so an
  `Info.plist` edited by hand is silently discarded on the next `generate`.
- `Application Support` does not exist on iOS until something creates it, so the
  first `save()` failed with "the folder doesn't exist" and every session lost
  its library.
- The first profile used `Units.formatDistanceAxis` as the chart's x *value*.
  That is a `String`, so 7,153 points became 7,153 categorical ticks: an
  unreadable x-axis and a y-domain in the millions of feet. Axes now carry raw
  metres and only the labels are converted.
- The profile and the statistics were computed from **three different
  samplings**: stats from the raw vertices, distance from the raw vertex chain,
  and the chart from its own thinning. The web app resamples once at
  `STATS_PROFILE_STEP_METERS` and derives the stats, the chart, and the distance
  along from that single array, so the bar and the curve cannot disagree. They
  now share one `RouteProfile` (`RouteAnalysis`).
- The profile ignored `TerrainTileStore.elevationAt`, the port of the web's
  `elevationAt`. `Profile.routeSamples` keeps elevation only on the original
  vertices and returns `nil` for the interpolated samples, so a GPX whose fixes
  are far apart — the 14-point demo route, for one — had a profile of a dozen
  dots and statistics that only saw those dozen points. The gaps are now filled
  from MapTiler's Terrain-RGB tiles, exactly as the web does, and vertex
  elevations are never overwritten.

Three porting bugs worth recording, all found by the tests rather than review:

- `TerrainRGB.bilinearSample` interpolated the bottom row with `dy` instead of
  `dx`, so every DEM sample off the top row was wrong.
- The GPX parser assigned text on every `XMLParser` `foundCharacters` callback.
  That callback splits at entity boundaries, so `A &amp; B &lt;C/&gt;` truncated
  to `>`. Text is now buffered and committed on element close.
- The search trail/trailhead patterns lost the web regex's case-insensitive flag,
  so "Eagle Valley Trail" never matched.
- The corridor builder offset in metres but added to degrees, turning a 1 km
  buffer into a 1000° offset, and built its tile-y range backwards (south
  latitude is a *larger* tile y), which trapped at runtime.

**M0 Spike — verified, except offline packs (see §9).**

| Gate item | State |
| --- | --- |
| Xcode project + SPM | **Done.** `xcodegen` → `ios/App/GPXNav.xcodeproj`; `xcodebuild` succeeds. |
| MapLibre renders | **Done**, against both the MapLibre demo basemap and MapTiler. |
| Route layer + fit + stats | **Done.** Verified on the simulator from RouteKit output. |
| Loopback slope server | **Done end to end.** Serves a real 512×512 RGBA PNG derived from MapTiler Terrain-RGB (`GET http://127.0.0.1:8080/slope/12/656/1583.png` → 200, ~27 KB), and the layer is visible on the map. |
| MapTiler style renders | **Done.** The key allows both web origins and the native `User-Agent` on the same key (§5.1), and the style, satellite style, Terrain-RGB tile, and geocoding all return 200. |
| `raster-dem` Terrain-RGB | **Done.** `MLNRasterDEMSource` over MapTiler Terrain-RGB renders hillshaded relief. |
| Offline pack survives airplane mode | **Superseded.** `addPack` succeeds but MapLibre never enumerates resources, so no tile is ever fetched through it. Offline now runs on our own tile cache instead — see the M5 row below and §9. Airplane-mode validation would additionally need a device, since `simctl` has no connectivity toggle. |

M0 defects the simulator surfaced, all fixed:

- The app **letterboxed** into a legacy compatibility window because no launch
  screen was declared. Fixed with `UILaunchScreen` in the plist.
- The MapTiler key **never reached the app**, so it silently ran on the demo
  basemap. `INFOPLIST_KEY_MaptilerAPIKey` is dropped by Xcode's generated
  plist — even as a literal — so the key had to move to a real plist entry,
  declared through `info.properties` in `project.yml` because xcodegen rewrites
  the plist file on every `generate`. A missing key now shows an explicit
  warning instead of quietly falling back to demo tiles.
- The offline download **spun forever**. Two causes: the pack was looked up by
  comparing regions with `===`, which never matches because MapLibre does not
  hand back the same `MLNShapeOfflineRegion` instance, and the stall timer was
  only armed in the `addPack` callback, so a pack that never called back was
  never timed out. Now matched by value, timed out from the start, and a failed
  attempt removes its pack instead of leaving dead ones in the database.

**M2 Viewer — mostly done.** The layer stack now matches the web app's
`addDataLayers`, verified with five routes in the library at once.

| Gate item | State |
| --- | --- |
| Full layer stack | **Done.** `route-casing` / `route-line` / `route-points` per route, waypoint circles, `location-accuracy` / `location-halo` / `location-dot`, relief, and slope, with the web app's paint values ported into `MapLayers.swift`. Route vertices are circle layers rather than annotations, for the same reason the web app moved them off DOM markers. |
| Multi-route | **Done.** Every visible route is drawn, not only the selected one; the selected route's vertices get the larger radius and dark stroke. Deleting or hiding a route removes its layers and sources. |
| Waypoints | **Done.** Drawn as a circle layer; they arrive from a GPX's `<wpt>` elements via `RouteKit.parseGPX` and persist with the workspace. |
| Fit | **Done.** Fit-to-bounds on the selected route, with the padding in `AppConfig`. |
| Locate | **Done.** `CLLocationManager` behind `LocationController`, with the same states the web app's `locate.ts` distinguishes. The accuracy disc is a polygon, so it stays glued to the ground. |
| Search | **Done.** Debounced 300 ms, six results, proximity biased to the route, and the Peak / Trailhead / Trail / Street badges from `RouteKit`. Tapping a result adds it as a waypoint. Verified against the live endpoint: names, peak detection, and summit elevations all arrive. |
| 3D terrain toggle | **Built, not yet verified on the map.** The map now loads its style from the loopback endpoint with `?terrain=1`, and the toggle forces a style reload because that is the only way to add or drop the block. Needs a look at a pitched camera before it is called done. |
| Style builder | **Built.** `StyleBuilder` fetches MapTiler's hosted style, adds a `raster-dem` source named `terrain` with an inline `tiles` template, and writes `"terrain": { "source": "terrain", "exaggeration": 1.15 }` — the same source name and exaggeration the web app's `setTerrain` call uses. The basemap is still MapTiler's own; only the terrain block is added. Served from the existing loopback listener at `/style.json?style=…&terrain=…`, cached per variant. |

Two MapLibre Native constraints cost rework here, both found by compiling
against the real headers rather than by reading docs:

- There is no shape-collection source. The web app's single geometry-filtered
  `location` GeoJSON source has to become two sources on native — one point,
  one accuracy polygon — which is why the two layers no longer share an id.
- `MLNMultiPoint` is abstract, despite being the obvious type for a set of
  route vertices. The concrete class is `MLNPointCollection`, whose ObjC factory
  imports into Swift as `init(coordinates:count:)`.

A design note for §9: the plan's literal "test each tile centre against
distance-to-route" **selects nothing at low zoom**, because a z12 tile is ~9.8 km
across while the buffer is ~1 km. The implementation keeps the intent but uses a
tolerance of `buffer + tile half-diagonal`, which still discards the inside-corner
tiles a bounding rectangle would grab. For a 10 km route that yields 126 tiles,
inside the plan's own 100–200 estimate. The plan's "8–15 MB" is *not* matched,
and the gap is not a rounding error: the estimate table is sized for vector and
Terrain-RGB tiles, while that figure appears to assume satellite rasters, which
are much larger at high zoom. The in-app estimate is therefore reported as
computed rather than tuned to hit the plan's number.

**M5 Offline — the mechanism works; the gate is a device.**

| Gate item | State |
| --- | --- |
| Every tile passes through disk | **Done.** `StyleBuilder` resolves each TileJSON, learns MapTiler's template, and repoints the style at `/tiles/{source}/{z}/{x}/{y}.{ext}` on the loopback. A hit is answered from the cache and never reaches the network; a miss fetches and stores. |
| Corridor prefetch | **Done.** Downloads the route's corridor for **every source the loaded style declares**, z12–z14, four requests in flight. Verified on the simulator: 68 tiles / 4.4 MB for the Maroon Bells loop, with `outdoor`, `contours`, `maptiler_planet`, and `terrain` each present as their own files. |
| Satellite basemap offline | **Done.** Raster sources go through the same seam, so `satellite`'s jpg tiles are cached alongside the labels. Verified with `-satellite`. |
| Per-source tile identity | **Fixed.** The cache was keyed by `z/x/y` alone, so all four sources collided: `contours` was answered with `outdoor`'s bytes, and a prefetch of four sources fetched one. `TileCacheKey` (source, coordinates, format) now owns the identity, with the loopback path round trip under test. |
| Elevation offline | **Done.** The DEM is cached as `raster-dem` source `terrain` across z12–z14 — not just z14, because MapLibre asks for a DEM tile at the camera's zoom — and the slope generator decodes the cached bytes rather than re-fetching. |
| Size estimate | **Measured, per source.** `TileSourceSize` replaces a flat per-format table that was 5× high for satellite rasters and 5× low for the DEM. See §9. |
| Progress and honesty | **Done.** Per-tile progress; a partial download reports how many tiles it could not fetch rather than claiming clean coverage, and Settings shows the cache's size with a way to clear it. |
| Full hike in airplane mode | **Not yet run.** The disk-hit path is verified two ways — a unit test that a stored tile is answered without the upstream closure ever being called, and a live check that a sentinel written into a cache file comes back byte-for-byte over the loopback — but the end-to-end gate still wants a physical device, since `simctl` has no connectivity toggle. |

## 11. Risks

1. **`raster-dem` custom encoding** unsupported on Native iOS ([#2783]). M0 item
   one; it gates both 3D terrain and hillshade. **Narrowed:** `MLNRasterDEMSource`
   documents support for the Mapbox Terrain-RGB encoding only, which is what
   MapTiler serves — so the risk is narrower than the style-spec matrix implies.
   Still unverified.
2. **No `addProtocol`** on Native. Slope rasters need the loopback `NWListener`
   workaround — the most complex piece in the plan. **Confirmed** during M0: the
   delegate's tile callback is observational only, and
   `MLNNetworkConfiguration` is the supported hook for custom tile-request headers.
   **Now load-bearing twice over:** the same listener is what puts every basemap
   and DEM tile on disk, so it is not only a slope-shading workaround but the
   offline mechanism itself (§9).
3. **MapTiler terms on offline caching** in a distributed app. **Unresolved, and
   now urgent** — the app caches MapTiler tiles on the user's device and serves
   them back with no network. A licensing question, not an engineering one, and it
   can invalidate §9 entirely.
4. **Swift 6 concurrency** against an unaudited Obj-C framework. **Confirmed
   real:** `MLNOfflinePack` is non-`Sendable` and cannot be retained, sent across
   an isolation boundary, or even captured in a completion handler. The offline
   manager no longer touches packs, so this is now only a constraint on any future
   MapLibre object that has to be held.
5. **MapTiler key restrictions do not transfer to native** (§5.1). Not a
   MapTiler bug, but it invalidates the plan's original key guidance: the key
   needs both an origin allowlist and a user-agent allowlist, and the iOS
   half of that is easy to leave out.
6. **No cache eviction.** `TileCache` drops its whole in-memory corpus at 32 MB
   and has no LRU on disk, so the cache only shrinks when the user clears it from
   Settings. Fine while a download is one corridor; worth revisiting before
   offline packs for several routes, or a satellite basemap over a long trip.

## 12. Open questions

- **Bundle ID — settled as `com.example.GPXNav` for now** (widget
  `com.example.GPXNav.GPXNavWidgets`). `com.example` is a reserved placeholder
  that App Store distribution will reject, and MapTiler may reject it as a
  native app identifier, so this must become a real reverse-DNS id — and the
  user-agent allowlist string changes with it — before shipping. Decide before M4,
  since the Live Activity and any App Groups are keyed to it.
- Apple Developer **team** id, still empty in `project.yml`; needed to run on a
  physical device.
- Confirm App Store distribution rather than personal signing. It determines the
  notification authorization level available, and whether CarPlay is reachable
  later at all.
- Seed the app with the existing demo tracks in `web/public/demos/`. Currently a
  hardcoded `DemoData.route` stands in; the document picker lands in M2.
- **Collapsible panel mechanism** (§7). A two-state collapse is the simpler
  thing to build and to reason about; a draggable sheet with detents is nicer to
  use but adds gesture handling that has to coexist with the map's own pan and
  pinch. Worth deciding before M2's layout work, because the map overlay
  structure depends on it.
- **What "fix the download" means** (§9) — **settled.** `MLNOfflineStorage` was
  dropped in favour of a tile cache every map request already passes through, so
  the button is enabled and the download works. What is left is the licensing
  question, not an engineering one, plus a real airplane-mode run on a device.
- **Whether the Create tab draws freehand or snaps to trails.** The web app snaps
  to marked trails and peaks (`trailGraph`, `snapSources`), and §3 keeps
  `snap.ts` partly. Snapping is more useful on a phone but pulls in the vector
  tile decoding that §3 lists as dropped. Freehand-only is much less work and
  loses the feature that makes drawn routes follow real paths.
