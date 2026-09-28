import SwiftUI
import RouteKit

/// Create a route: search for places and drop them as waypoints.
///
/// Drawing the line itself is the next step, and the search results already
/// land here as waypoints, which is what the drawn line will be anchored to.
/// See docs/ios-plan.md §7 and §12.
struct CreateView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @StateObject private var draft = DraftRoute()
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if draft.waypoints.isEmpty {
                        ContentUnavailableView(
                            "Nothing placed yet",
                            systemImage: "mappin.and.ellipse",
                            description: Text("Search for peaks, trailheads, and trails to place waypoints.")
                        )
                    } else {
                        ForEach(Array(draft.waypoints.enumerated()), id: \.offset) { index, waypoint in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(waypoint.name)
                                    if let elevation = waypoint.elevation {
                                        Text(Units.formatElevation(elevation, system: workspace.unitSystem))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    draft.removeWaypoint(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(waypoint.name)")
                            }
                        }
                        .onMove { draft.moveWaypoints(from: $0, to: $1) }
                    }
                } header: {
                    Text("Waypoints")
                } footer: {
                    Text("Drawing the line between them is next. The GPX export follows that.")
                }

                Section("Actions") {
                    Button("Search for a place", systemImage: "magnifyingglass") {
                        isSearching = true
                    }
                    Button("Clear", systemImage: "xmark.circle", role: .destructive) {
                        draft.clear()
                    }
                    .disabled(draft.waypoints.isEmpty)
                }
            }
            .navigationTitle("Create")
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .environment(\.editMode, .constant(draft.waypoints.isEmpty ? .inactive : .active))
        }
        .sheet(isPresented: $isSearching) {
            SearchView(proximity: nil) { result in
                draft.addWaypoint(result)
            }
        }
    }
}

/// The in-progress route on the Create screen.
///
/// Deliberately separate from `WorkspaceStore`: a half-built route is not part of
/// the saved workspace, and it should not survive a relaunch. It is a controller
/// for this screen, not a view model hanging off the view.
@MainActor
final class DraftRoute: ObservableObject {
    @Published private(set) var waypoints: [Waypoint] = []

    func addWaypoint(_ result: GeocodeResult) {
        waypoints.append(Waypoint(
            lat: result.center.lat,
            lon: result.center.lon,
            name: result.name,
            elevation: result.elevation
        ))
    }

    func removeWaypoint(at index: Int) {
        guard waypoints.indices.contains(index) else { return }
        waypoints.remove(at: index)
    }

    func moveWaypoints(from source: IndexSet, to destination: Int) {
        waypoints.move(fromOffsets: source, toOffset: destination)
    }

    func clear() {
        waypoints = []
    }

    /// The GPX document for the current waypoints, for when drawing lands.
    var gpx: String {
        GPXWriter.export(routes: [], waypoints: waypoints)
    }
}
