import SwiftUI
import UniformTypeIdentifiers
import RouteKit
import UIKit

/// The three tabs: Create, Navigate, Settings.
///
/// Navigate holds the map list for now and behaves like the old Library tab;
/// it becomes live guidance in M3. See docs/ios-plan.md §7.
struct RootTabView: View {
    enum Tab: Hashable { case library, settings }

    /// `-openFirstRoute` deep-links into a route, so it has to start on the tab
    /// that owns the list rather than the default one.
    @State private var selection: Tab = RootTabView.initialTab

    /// The tab to open on, read from the launch arguments.
    ///
    /// `simctl` cannot tap, so the Settings screen — which is the only place the
    /// basemap picker, the relief and slope toggles and the units picker live —
    /// was unreachable from a script. `-tab settings` is how the CI preview in
    /// `ios/ci/capture.sh` gets a frame of it. See `docs/dev.md`.
    ///
    /// An unknown or missing value falls back to Create rather than trapping:
    /// a typo in a flag should not change which tab the app opens on for a
    /// person who did not pass it deliberately.
    static var initialTab: Tab {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-tab"),
              arguments.count > index + 1 else {
            return .library
        }
        switch arguments[index + 1].lowercased() {
        case "settings":
            return .settings
        default:
            return .library
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            LibraryMapsView()
                .tabItem { Label("Library", systemImage: "map") }
                .tag(Tab.library)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(Tab.settings)
        }
    }
}

extension Notification.Name {
    static let switchToCreate = Notification.Name("switchToCreate")
    static let switchToEditor = Notification.Name("switchToEditor")
    static let switchToViewer = Notification.Name("switchToViewer")
}


/// Library of GPX maps.
struct LibraryMapsView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var path: [LibraryDestination] = []
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var showNewMapWarning = false

    enum LibraryDestination: Hashable {
        case viewer(MapDocument)
        case editor(Int)
    }

    private var visibleMaps: [MapDocument] { workspace.maps.filter { $0.hasFinishedRoutes } }

    var body: some View {
        libraryNavigation
    }

    private var libraryNavigation: some View {
        NavigationStack(path: $path) {
            libraryList
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToEditor)) { _ in
            path.append(.editor(workspace.selectedMapId ?? -1))
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToViewer)) { _ in
            guard let map = workspace.selectedMap, map.hasFinishedRoutes else { return }
            if case .viewer(let existing) = path.last, existing.id == map.id { return }
            path.append(.viewer(map))
        }
    }

    private var libraryList: some View {
        List {
            if visibleMaps.isEmpty {
                ContentUnavailableView(
                    "No maps yet",
                    systemImage: "map",
                    description: Text("Import a GPX, or create a new map.")
                )
            }
            ForEach(visibleMaps) { map in
                NavigationLink(value: LibraryDestination.editor(map.id)) {
                    libraryRow(map)
                }
            }
            .onDelete { offsets in
                deleteMaps(offsets)
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
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    Button("Export", systemImage: "square.and.arrow.up") {
                        prepareExport()
                    }
                    .disabled(workspace.maps.isEmpty)
                    Button("Import", systemImage: "square.and.arrow.down") {
                        isImporting = true
                    }
                    Button("New", systemImage: "plus") {
                        if hasUnsavedChanges {
                            showNewMapWarning = true
                        } else {
                            let map = workspace.newMap()
                            path = [.editor(map.id)]
                        }
                    }
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
        .sheet(isPresented: $isExporting) {
            if let exportURL {
                ActivityView(url: exportURL)
            }
        }
        .navigationDestination(for: LibraryDestination.self) { destination in
            navigationDestinationView(destination)
        }
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("-openFirstRoute"), path.isEmpty else { return }
            guard let map = visibleMaps.first else { return }
            path.append(.editor(map.id))
        }
        .alert("Discard current unsaved map?", isPresented: $showNewMapWarning) {
            Button("Discard", role: .destructive) {
                if let id = workspace.selectedMapId, workspace.selectedMap?.hasFinishedRoutes != true {
                    workspace.maps.removeAll { $0.id == id }
                    workspace.selectedMapId = workspace.maps.first?.id
                }
                workspace.draft = nil
                workspace.save()
                let map = workspace.newMap()
                path.append(.editor(map.id))
            }
            Button("Keep Editing", role: .cancel) { }
        }
    }

    private var hasUnsavedChanges: Bool {
        if let draft = workspace.draft, !workspace.routes.contains(where: { $0.id == draft.id }) {
            return true
        }
        guard let selected = workspace.selectedMap, !selected.hasFinishedRoutes else {
            return false
        }
        return !workspace.waypoints.isEmpty
    }

    private func deleteMaps(_ offsets: IndexSet) {
        let actualOffsets = offsets.map { idx -> Int in
            let id = visibleMaps[idx].id
            return workspace.maps.firstIndex { $0.id == id } ?? idx
        }
        for offset in actualOffsets.sorted(by: >) {
            if offset < workspace.maps.count {
                workspace.maps.remove(at: offset)
            }
        }
        workspace.save()
    }

    @ViewBuilder private func navigationDestinationView(_ destination: LibraryDestination) -> some View {
        switch destination {
        case .viewer(let map):
            Group {
                if let route = map.routes.first {
                    ViewerScreen(route: route)
                } else {
                    EmptyView()
                }
            }
            .environmentObject(workspace)
            .onAppear { workspace.selectMap(map.id) }
        case .editor(let id):
            CreateView(mapId: id)
        }
    }


    private func libraryRow(_ map: MapDocument) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: map.routes.first?.color ?? "#2563eb"))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(map.name)
                Text("\(map.routes.count) routes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func prepareExport() {
        let gpx = GPXWriter.export(routes: workspace.routes, waypoints: workspace.waypoints, name: workspace.documentName)
        let base = (workspace.documentName ?? "map").replacingOccurrences(of: ".gpx", with: "")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(base).gpx")
        try? gpx.write(to: url, atomically: true, encoding: .utf8)
        exportURL = url
        isExporting = true
    }

    private func importGPX(_ result: Result<[URL], any Error>) {
        switch result {
        case .failure(let error):
            workspace.importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let newMap = workspace.newMap()
                workspace.selectMap(newMap.id)
                if workspace.importGPX(text, fileName: url.lastPathComponent) {
                    if let imported = workspace.selectedMap {
                        path.append(.editor(imported.id))
                    }
                } else {
                    workspace.maps.removeAll { $0.id == newMap.id }
                    workspace.selectedMapId = workspace.maps.first?.id
                    workspace.save()
                }
            } catch {
                workspace.importError = error.localizedDescription
            }
        }
    }

    private struct ViewerForMap: View {
        @EnvironmentObject private var workspace: WorkspaceStore
        let map: MapDocument

        var body: some View {
            Group {
                if let route = map.routes.first {
                    ViewerScreen(route: route)
                } else {
                    EmptyView()
                }
            }
            .environmentObject(workspace)
            .onAppear { workspace.selectMap(map.id) }
        }
    }
}


struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
