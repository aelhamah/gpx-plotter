import SwiftUI
import RouteKit

/// Geocoding search, ported from the web app's `geocode.ts` flow: debounced as
/// you type, at most six results, proximity biased to where the map is looking,
/// and the same Peak / Trailhead / Trail / Street badges.
struct SearchView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [GeocodeResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    /// Where the map is looking, which biases results toward it.
    var proximity: Coordinate?
    /// Called with the chosen result. Create passes this to collect a waypoint;
    /// the viewer leaves it nil and dismisses instead.
    var onSelect: ((GeocodeResult) -> Void)?

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView(
                        "Search for a place",
                        systemImage: "magnifyingglass",
                        description: Text("Peaks, trailheads, trails, and streets.")
                    )
                } else if isSearching && results.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(results, id: \.id) { result in
                        resultRow(result)
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Peak, trail, or street")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onChange(of: query) { _, newValue in
                scheduleSearch(for: newValue)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func resultRow(_ result: GeocodeResult) -> some View {
        Button {
            add(result)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                        .foregroundStyle(.primary)
                    if !result.region.isEmpty {
                        Text(result.region)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !result.typeLabel.isEmpty {
                    Text(result.typeLabel.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if let elevation = result.elevation {
                    Text(Units.formatElevation(elevation, system: workspace.unitSystem))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Search results become waypoints, which is what the web app does with a
    /// tapped geocoding result too.
    private func add(_ result: GeocodeResult) {
        if let onSelect {
            onSelect(result)
            dismiss()
            return
        }
        workspace.waypoints.append(
            Waypoint(
                lat: result.center.lat,
                lon: result.center.lon,
                name: result.name,
                elevation: result.elevation
            )
        )
        workspace.save()
        dismiss()
    }

    /// Debounce so a fast typist makes one request, not one per keystroke.
    private func scheduleSearch(for text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        let center = proximity
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = await AppConfig.geocodingClient?.geocode(
                trimmed,
                options: GeocodeOptions(proximity: center)
            ) ?? []
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}
