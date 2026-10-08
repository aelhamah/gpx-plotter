import SwiftUI
import UniformTypeIdentifiers
import RouteKit

/// The three tabs: Create, Navigate, Settings.
///
/// Navigate holds the map list for now and behaves like the old Library tab;
/// it becomes live guidance in M3. See docs/ios-plan.md §7.
struct RootTabView: View {
    enum Tab: Hashable { case create, navigate, settings }

    /// `-openFirstRoute` deep-links into a route, so it has to start on the tab
    /// that owns the list rather than the default one.
    @State private var selection: Tab = ProcessInfo.processInfo
        .arguments.contains("-openFirstRoute") ? .navigate : .create

    var body: some View {
        TabView(selection: $selection) {
            CreateView()
                .tabItem { Label("Create", systemImage: "square.and.pencil") }
                .tag(Tab.create)

            MapsListView()
                .tabItem { Label("Navigate", systemImage: "location.north.fill") }
                .tag(Tab.navigate)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(Tab.settings)
        }
    }
}

/// The list of maps, titled "Maps": a map is what the user is picking, and the
/// same list holds routes that arrived from a GPX export as well as an import.
struct MapsListView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var path: [Route] = []
    @State private var isImporting = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if workspace.routes.isEmpty {
                    ContentUnavailableView(
                        "No maps yet",
                        systemImage: "map",
                        description: Text("Import a GPX, or draw one in Create.")
                    )
                }
                ForEach(workspace.routes) { route in
                    NavigationLink(value: route) {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: route.color))
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(route.name)
                                if let summary = RouteSummary(route: route, system: workspace.unitSystem) {
                                    Text(summary.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    workspace.routes.remove(atOffsets: offsets)
                    workspace.save()
                }

                if let error = workspace.importError {
                    Label {
                        Text(error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                    .font(.caption)
                }
            }
            .navigationTitle("Maps")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Import", systemImage: "square.and.arrow.down") {
                        isImporting = true
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml],
                allowsMultipleSelection: false
            ) { result in
                importGPX(result)
            }
            .navigationDestination(for: Route.self) { route in
                ViewerScreen(route: route)
            }
        }
        .onAppear {
            // `-openFirstRoute` opens the map straight away, so the M0 spike
            // (style + route + overlays) can be driven from `simctl launch`. It
            // prefers the last-opened route, which import and navigation set.
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("-openFirstRoute"), path.isEmpty else { return }
            let selected = workspace.routes.first { $0.id == workspace.selectedRouteId }
            if let route = selected ?? workspace.routes.first {
                path.append(route)
            }
        }
    }

    private func importGPX(_ result: Result<[URL], any Error>) {
        switch result {
        case .failure(let error):
            workspace.importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // The picker hands back a security-scoped URL; without this the
            // read fails with a permissions error.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                if workspace.importGPX(text, fileName: url.lastPathComponent) {
                    path.append(workspace.routes[workspace.routes.count - 1])
                }
            } catch {
                workspace.importError = error.localizedDescription
            }
        }
    }
}
