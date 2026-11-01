# iOS Library Reorg Plan

## Goal

Combine the iOS Create and Navigate tabs into one Library. A library item is a GPX
document that can contain multiple routes and waypoints. Only maps with at least
one finished route appear in Library. Route creation stays in edit mode until
manually exited, supports waypoint-only maps, and warns before discarding
unsaved work.

## Product decisions

- Library becomes the launch root.
- Create and Navigate are merged into Library.
- Settings remains a separate tab.
- One library item is a GPX document containing multiple routes and waypoints.
- Only documents with at least one finished route appear in Library.
- Create remains in edit mode until manually exited.
- New maps do not auto-create a route; the user taps `Draw` first.
- Waypoint-only maps are allowed, but they warn before discard if they have
  unfinished edits.
- Search remains editor-only.
- Created/imported routes appear in Library only after they become finished
  routes.
- Existing Viewer edit pencil continues to open the map editor.

## Data model

- Add `MapDocument` with:
  - `id`
  - `name`
  - `routes: [Route]`
  - `waypoints: [Waypoint]`
  - `draft: Route?`
  - `selectedRouteId: Int?`
  - `nextRouteId: Int`
- Store a `maps: [MapDocument]` collection.
- Track `selectedMapId`.
- Keep selected-map convenience accessors for current routes, waypoints, and
  draft so existing editing code can remain focused.
- Each finished `Finish` action promotes `draft` into that map's `routes`.
- Cancel discards an unfinished draft and removes a map with no finished routes.

## App structure

- `RootTabView`: `Library` tab + `Settings` tab only.
- `Library` is a `NavigationStack` over documents.
- Top trailing toolbar:
  - New Map
  - Import GPX
- Library rows open Viewer for a concrete route, or the first finished route.
- Viewer edit pencil opens that map's editor.
- `CreateEditor` is pushed from:
  - `New Map`
  - Viewer edit pencil
- `New Map` opens an empty document in edit mode without immediately creating
  a route. The user must tap `Draw`.
- Search is only displayed in `CreateEditor`.

## Editing and persistence

- Editor edits `workspace.draft`.
- Treat every accepted command as autosaving.
- Persist on:
  - point addition
  - vertex movement
  - vertex drag completion
  - waypoint creation
  - waypoint snap completion
  - route name change
  - map name change
  - waypoint name change
  - snap toggle change
  - finish route
- Every persisted writes the selected document into the map collection.
- `Finish` appends or replaces the route, selects it, keeps the same document
  open.
- `Cancel` prompts when:
  - there is a draft route, or
  - there are pending edits in the map.
- New Map / Import while editing must warn instead of silently replacing the
  active draft.
- Exit editor button returns to Library after confirmation.

## Migration

- Bump workspace persistence version.
- Convert old single-workspace JSON into one `MapDocument`.
- Keep backward aliases for legacy `-tab create` and `-tab navigate`; both map
  to `Library`.
- Add tests for migration.

## Implementation phases

1. Add `MapDocument` and storage versioning to RouteKit.
2. Add library/document access to WorkspaceStore while preserving selected-map
   accessors.
3. Convert app global route assumptions to the selected document.
4. Combine Create and Navigate into Library.
5. Move metadata naming into the editor.
6. Add discard warnings.
7. Update capture scripts and launch arguments.

## Validation steps for iOS

### Build and package

- `cd ios/RouteKit && swift build && swift test`
- `cd ios/App && xcodegen generate && xcodebuild -project GPXNav.xcodeproj -scheme GPXNav -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`

### Migration

- Decode old persisted `workspace.json`.
- Verify one map is created.
- Verify routes, waypoints, draft, next id, selected route, document name, and
  unit system are preserved.

### Library

- `simctl launch ... com.aelhamah.GPXNav` opens Library.
- Empty state appears on fresh install.
- New Map opens editor without a route.
- Waypoint-only maps do not appear before Finish.
- A map appears after its first finished route.
- App relaunch shows saved maps.

### Editor

- `Draw` creates one draft route only when tapped.
- Multiple routes can be finished in one session.
- Undo/redo remain local to current command set.
- Restarting app during edit returns the draft.
- Change map/route/waypoint names and verify persistence after relaunch.
- Search appears only in editor and works for waypoint creation.
- Exit with unsaved draft prompts and correctly discards.
- Exit with finished routes returns to Library without losing them.

### Viewer

- Pencil opens the exact map that owns the route.
- Navigation remains available for finished routes.
- Return from editor to Library does not duplicate routes.

### Capture/tests

- Update `ios/ci/capture.sh` scenes and arguments to Library/editor terms.
- Add unit tests for `MapDocument` encoding/decoding and selected-map mutations.
- Add model tests for finish/cancel/new map behavior where possible.
