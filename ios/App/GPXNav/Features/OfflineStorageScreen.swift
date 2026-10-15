import RouteKit
import SwiftUI

/// What is on disk, and what may be deleted.
///
/// The cache warms itself as the map is panned, so it is not a list of downloads
/// and this screen does not pretend otherwise: the corridors the user asked for
/// are listed, and whatever is left over is reported as browsing on its own line.
/// Hiding that remainder is what would make the numbers stop adding up.
struct OfflineStorageScreen: View {
    @ObservedObject var packs: OfflinePackManager
    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        List {
            if packs.packs.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No offline maps",
                        systemImage: "icloud",
                        description: Text("Download a route's corridor from its offline row and it will be listed here.")
                    )
                }
            } else {
                Section {
                    ForEach(packs.packs) { pack in
                        row(for: pack)
                    }
                } header: {
                    Text("Downloaded")
                } footer: {
                    Text("\(packs.packs.count) corridor\(packs.packs.count == 1 ? "" : "s") · \(OfflineStorageScreen.describe(packs.packs.reduce(0) { $0 + $1.byteCount })) recorded at download time.")
                }
            }

            Section {
                LabeledContent("On disk") {
                    Text("\(packs.cachedTileCount) tiles · \(OfflineStorageScreen.describe(packs.cachedBytes))")
                        .foregroundStyle(.secondary)
                }
                if packs.unattributedTileCount > 0 {
                    LabeledContent("From browsing") {
                        Text("\(packs.unattributedTileCount) · \(OfflineStorageScreen.describe(packs.unattributedBytes))")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Cache")
            } footer: {
                Text(packs.unattributedTileCount > 0
                     ? "Tiles are cached as you look at the map, so most of the cache belongs to no route. They are kept because they make the map work without a network, and \"Clear all\" removes them too."
                     : "Tiles are cached as you look at the map, and a corridor download fetches the rest for a route.")
            }

            if packs.canFreeSpace {
                Section {
                    Button("Free Up Space", role: .destructive) {
                        packs.freeSpace()
                    }
                } footer: {
                    Text("Removes the oldest corridors until the recorded total is within \(OfflineStorageScreen.describe(AppConfig.offlineByteBudget)). Nothing is removed automatically.")
                }
            }

            Section {
                Button("Clear Offline Maps", role: .destructive) {
                    packs.removeAllTiles()
                }
                .disabled(packs.cachedTileCount == 0 || packs.isPruning)
            } footer: {
                Text("Removes every cached tile and every record above.")
            }
        }
        .navigationTitle("Offline Storage")
        .task { await packs.refreshCacheFigures() }
        .task { await packs.refreshAttribution() }
        .disabled(packs.isPruning)
        .overlay {
            if packs.isPruning {
                ProgressView()
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Rows

    private func row(for pack: OfflinePack) -> some View {
        let route = workspace.routes.first { $0.id == Int(pack.id) }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(pack.tileCount) tiles · \(OfflineStorageScreen.describe(pack.byteCount)) · \(Self.when(pack.downloadedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                packs.deletePack(pack, route: route)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete offline map for \(pack.name)")
        }
    }

    // MARK: - Formatting

    /// Bytes as the offline bar already says them, so the two screens cannot
    /// disagree about whether something is 4.4 MB or 0.0 MB.
    static func describe(_ bytes: Int) -> String {
        OfflinePackManager.describe(bytes: bytes)
    }

    private static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}