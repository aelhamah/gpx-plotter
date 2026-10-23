import Foundation
@preconcurrency import MapLibre

/// The second cache the map has, and the only way to clear it.
///
/// ## Why this exists
///
/// The app already has a tile cache, and it is a deliberate one: `StyleBuilder`
/// repoints every basemap source at the loopback listener, so each tile passes
/// through disk on its way in and out. That is what makes an offline map work.
///
/// MapLibre keeps a cache of its own behind the same requests, and that second
/// cache is invisible: it is not in `Application Support/tiles`, so the storage
/// screen's figures do not include it, and "Clear Offline Maps" did not touch it,
/// so nothing in the app could. The two are not the same thing and never were.
///
/// It can also go bad in a way the first one cannot. MapTiler answers **502**
/// above a tileset's `maxzoom` rather than overzooming, so a camera pushed past it
/// by an uncapped route fit collects empty responses. Once those are on disk,
/// MapLibre considers the area cached, stops asking for it, and draws nothing —
/// and keeps drawing nothing on every later launch, because nothing invalidates
/// it. The symptom is a background-coloured panel with the route drawn on top of
/// it (that line is an overlay of ours and needs no tile), and the one thing that
/// fixes it is deleting a cache the user cannot see and cannot clear.
///
/// So: stop it accumulating, and make it clearable.
///
/// - Note: `MLNOfflineStorage` is MapLibre's own class, not ours; this only wraps
///   the two calls needed to reach its cache.
enum MapLibreCache {
    /// Whether MapLibre should keep its own copy of every tile.
    ///
    /// Off, deliberately. The loopback cache already answers from disk, so
    /// MapLibre's second copy buys nothing but the failure mode above — and this
    /// way the storage screen's byte count is the whole truth about what is on
    /// the device.
    static let isEnabled = false

    /// Empty MapLibre's cache.
    ///
    /// Asynchronous because MapLibre closes and reopens the database; the
    /// completion reports what went wrong so a caller can say so rather than
    /// implying success.
    static func clear() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            MLNOfflineStorage.shared.resetDatabase { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Where MapLibre's cache lives, for a diagnostic or a bug report.
    static var databasePath: String {
        MLNOfflineStorage.shared.databasePath
    }
}