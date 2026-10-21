import Foundation
import RouteKit

/// Formatting both ends of the Live Activity share, so the lock screen and the
/// nav screen cannot print the same number two different ways.
///
/// The activity runs in its own process with no access to the app's formatters,
/// so anything it shows has to be written down twice or written down here.
enum HikeFormat {
    /// Grade as a climb-or-descend arrow, because "8%" on its own does not say
    /// whether the hill is going up.
    ///
    /// `gradeAheadPercent` is a rise-over-run *percentage*, while the arrow bands
    /// and `Units.formatSlope` both want degrees, so this converts rather than
    /// labelling a percentage with a degree sign. Flat ground gets the bare
    /// angle: the level bar beside a `0°` read like the missing-value dash with
    /// a number stuck to it.
    static func grade(_ percent: Double?) -> String? {
        guard let percent else { return nil }
        let degrees = atan(percent / 100) * 180 / .pi
        let angle = "\(Int(degrees.rounded()))°"
        guard degrees > 1 || degrees < -1 else { return angle }
        return "\(degrees > 1 ? "▲" : "▼") \(angle)"
    }
}