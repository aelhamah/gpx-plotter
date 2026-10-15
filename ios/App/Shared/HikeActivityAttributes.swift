import ActivityKit
import Foundation
import RouteKit

/// The contract between the app and its Live Activity, in one file compiled into
/// both targets.
///
/// ActivityKit needs the *same* `ActivityAttributes` type on both sides of the
/// wire, and the two targets cannot share a framework: the app is a UIKit app and
/// the extension is a widget. A file in both targets' sources is the way to do it
/// without inventing a package for two types.
///
/// Everything here has to survive being encoded into the activity's 4 KB content
/// budget and be readable by a process that is not the app — which is why the
/// numbers are metres, percentages, and plain strings, and never a `Route`.
/// Formatting happens at the far end, in the widget.
struct HikeActivityAttributes: ActivityAttributes, Sendable {

    /// What changes as the hiker walks, sent on every update.
    ///
    /// The fields are the nav screen's readout, unchanged: the whole point of the
    /// activity is that the same numbers are legible without unlocking the phone.
    struct ContentState: Codable, Hashable, Sendable {
        /// Metres along the route so far.
        var distanceAlong: Double
        /// Metres still to walk.
        var remaining: Double
        var currentElevation: Double?
        /// Rise over run, as a percentage, over the next stretch.
        var gradeAheadPercent: Double?
        var nextWaypointName: String?
        var isOffCourse: Bool
        /// Metres from the route line, always carried so the activity can show
        /// *how* far off rather than only that it is.
        var offCourseMeters: Double
        /// Tracking has been paused from the lock screen.
        ///
        /// Not in the plan's sketch, and without it a paused hike is
        /// indistinguishable from a broken one: the numbers stop moving, the stale
        /// timer greys them out, and the hiker cannot tell which happened. One
        /// Bool is cheaper than that confusion.
        var isPaused: Bool
        /// The end of the route has been reached.
        ///
        /// Sent as a flag rather than left for the widget to infer from a small
        /// remaining distance: the arrival threshold is 30-60 m, it is the app's
        /// decision, and "0.03 mi left" on a hike that has finished reads as a
        /// rounding error rather than as an arrival.
        var hasArrived: Bool
    }

    // MARK: - Fixed for the life of the activity

    var routeName: String
    /// Metres end to end, so the widget can draw a progress bar without a second
    /// lookup. `ContentState.remaining` alone cannot say how far along that is.
    var totalDistance: Double
    var startedAt: Date
    /// Which units to print in.
    ///
    /// Not in the plan's sketch, and needed: the widget is a separate process with
    /// no App Group, so it cannot read the app's preference, and "3.42" is
    /// meaningless without knowing whether that is miles or kilometres. Sending it
    /// once here beats sending formatted strings on every update.
    var unitSystem: UnitSystem
}