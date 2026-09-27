# iOS app plan

A native iPhone/iPad app for viewing and navigating the same GPX routes as the
web app in [`web/`](../web), with offline satellite imagery you control, Live
Activity guidance, and off-course alerts.

**Status:** planned, not started. No `ios/` directory exists yet. This document
is the design; the work is broken into milestones in [§9](#9-milestones).

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
| `web/src/trailGraph.ts` | 188 | Dijkstra along trail polylines, snapping only |
| `web/src/snapSources.ts` | 210 | fetches trail/peak vector tiles for snapping |
| `web/src/snapTiles.ts` | 141 | picks the zoom and tile set a snap query needs |
| `web/src/merge.ts` | 90 | merging two routes |
| `web/src/drag.ts` | 3 | vertex drag threshold |
| `web/src/main.ts` edit machinery | ~700 of 1797 | draw / drag / merge / undo / dialogs / shortcuts |

That also drops the 63 tests in the five snapping suites (`mvt`, `snap`,
`snapTiles`, `snapSources`, `trailGraph`) of the 248 web tests, which are not
ported. `snap.ts` is partly kept — see the ported list below.

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

The MapTiler key ships in the app bundle. Restrict it by bundle ID.

## 6. Viewer

MapTiler `outdoor-v2` base, style JSON assembled at runtime from the URLs in
`web/src/config.ts`, plus the layer stack from `main.ts:addDataLayers()`:

- `route-casing` — white, width 8, opacity 0.88
- `route-line` — width 4, per-route colour from the palette
- `route-points` — **circle style layers, not annotations**, so they stay glued
  under pitch and terrain (same reasoning as web commit `89704c3`)
- `location-accuracy` / `location-halo` / `location-dot`

Toggles: satellite (`satellite-v4`), 3D terrain (`raster-dem`, exaggeration
1.15, ease pitch to 55°), relief, slope. Slope shading is off until the M0 spike
proves it works.

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

- **Loopback HTTP (preferred).** An `NWListener` on `127.0.0.1`; the style points
  the `slope` raster source at `http://127.0.0.1:<port>/slope/{z}/{x}/{y}.png`.
  Mirrors `addProtocol` almost one-to-one and works both online and inside
  offline packs. Needs `NSAllowsLocalNetworking`.
- **`MLNOfflineStorage.preloadData(_:for:…)`.** Compute the PNG and insert it
  under the exact URL the style requests. Clean and fully offline, but the app
  has to drive on-demand generation.

Also unverified: the style spec's support matrix marks `raster-dem` **custom**
encodings as unsupported on Native iOS ([#2783]). MapTiler `terrain-rgb-v2` uses
the *Mapbox* encoding (supported since 6.0.0), so it should work — but this is
the first thing the M0 spike checks, because if it fails we lose both 3D terrain
and hillshade.

## 7. Navigation

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

## 8. Offline

Offer a corridor download on import: the route polyline plus roughly a 1 km
buffer, testing each tile centre against distance-to-route rather than using a
rectangle, as an `MLNShapeOfflineRegion` for satellite z12–z16 plus DEM z14.

Ground tile size is `40075016.686 / 2^z` m, so a 10 km route works out to
roughly 100–200 tiles / 8–15 MB. Compute the real figure with
`MLNOfflineStorage` and show it to the user before they commit.
`MLNOfflineStorage` provides LRU eviction and an ambient cache for free.

**Before M5:** confirm MapTiler's terms permit offline tile caching in a
distributed app. That is a licensing question, not an engineering one, and it
can invalidate the approach.

## 9. Milestones

| | Scope | Gate |
| --- | --- | --- |
| **M0 Spike** | Xcode project + SPM, MapTiler style renders, `raster-dem` Terrain-RGB confirmed, loopback slope raster visible, offline pack survives airplane mode | **Go/no-go.** Slope shading is the first thing to cut if the loopback server misbehaves; if `raster-dem` fails, 3D terrain and hillshade both go |
| **M1 Core** | `RouteKit` + ~120 tests, GPX import, stats, Swift Charts profile | Import a GPX and see real numbers |
| **M2 Viewer** | Style builder, full layer stack, all toggles, waypoints, search, fit, locate | Visually matches the web app |
| **M3 Navigate** | `NavigationSession`, progress, off-course, nav UI, background location | Hike a real trail with the phone locked |
| **M4 Live Activity** | Widget extension, Dynamic Island | Glanceable from the lock screen |
| **M5 Offline** | Corridor prefetch, download manager, storage screen | Full hike in airplane mode |

## 10. Risks

1. **`raster-dem` custom encoding** unsupported on Native iOS ([#2783]). M0 item
   one; it gates both 3D terrain and hillshade.
2. **No `addProtocol`** on Native. Slope rasters need the loopback `NWListener`
   workaround — the most complex piece in the plan.
3. **MapTiler terms on offline caching** in a distributed app. Resolve before M5.
4. **Swift 6 concurrency** against an unaudited Obj-C framework.

## 11. Open questions

- Bundle ID and team, needed to stand up the project and lock the MapTiler key
  to it.
- Confirm App Store distribution rather than personal signing. It determines the
  notification authorization level available, and whether CarPlay is reachable
  later at all.
- Seed the app with the existing demo tracks in `web/public/demos/`.
