import SwiftUI
import CoreLocation
import RouteKit

/// The compass needle: a north glyph that turns to the bearing, but only in
/// heading mode.
///
/// Shared with the navigation screen's compass, because the two are the same
/// control and having them as separate implementations is how the widget's three
/// presentations ended up disagreeing about what state the hike was in.
struct CompassNeedle: View {
    @EnvironmentObject private var location: LocationController

    /// Stay a needle instead of falling back to the locate button's status
    /// glyphs.
    ///
    /// The navigation HUD's compass has no status to report: north-up is a mode
    /// it offers, not a fault, so it must not turn into a crosshair or a
    /// crossed-out pin when heading-follow is off. North-up is simply the
    /// needle pointing up.
    var alwaysNeedle = false

    var body: some View {
        Image(systemName: symbol)
            // Negated: the glyph points at north, so turning it clockwise by the
            // bearing is what puts *its* point where the device is facing. Zero
            // outside heading mode, because a needle spinning while the map stays
            // north-up would be the map lying twice over.
            .rotationEffect(.degrees(rotation))
    }

    private var rotation: Double {
        guard location.followsHeading, let heading = location.heading else { return 0 }
        return -heading
    }

    private var symbol: String {
        // The navigation HUD's compass stays a needle whatever the mode — the
        // one branch that must not fall into the cycle's glyphs, because
        // north-up there is simply the needle pointing up.
        if alwaysNeedle { return "location.north.line.fill" }
        switch location.followMode {
        case .orientation:
            return "location.north.line.fill"
        case .myLocation:
            return "location.fill"
        case .nothing:
            // The outlined pin while the map is free, so centred (solid) reads
            // apart from not-yet-following (outline) the way Apple Maps'
            // own arrow reads faint until it has you.
            switch location.status {
            case .located: return "location"
            case .locating: return "location.circle"
            case .denied, .unavailable: return "location.slash"
            case .idle: return "location"
            }
        }
    }
}

/// The map's locate button, with the same states the web app's `locate.ts`
/// distinguishes: locating, located, permission refused, and unavailable.
///
/// In heading mode the glyph is a compass needle that turns with the device, so
/// the control says which way is which without you having to compare it against
/// the map. It used to be a *static* north glyph: the same picture whatever you
/// were facing, which is #48's actual ask -- a compass that does not move is not a
/// compass.
struct LocateButton: View {
    @EnvironmentObject private var location: LocationController

    var body: some View {
        Button {
            // Nothing → my location → location orientation → my location → …,
            // one step per tap; see `LocationController.cycleLocateMode()`.
            // The first step is the one that centres, even when a fix is
            // already there.
            location.cycleLocateMode()
        } label: {
            CompassNeedle()
        }
        .buttonStyle(ChromeButtonStyle(tint: tint))
        .accessibilityLabel(label)
        .accessibilityHint(label)
        // The cycle ends where its stream was started: the magnetometer sleeps
        // with the button, and the mode goes back to *nothing*, whose first tap
        // is "my location" — the same rule as a fresh launch, so a returning
        // tab cannot inherit a beam pointing at where you faced an hour ago.
        .onDisappear {
            location.stopHeading()
            location.followMode = .nothing
        }
    }

    /// How far to turn the needle, in degrees.
    ///
    /// Negated, because the glyph points at north and rotating it clockwise by the
    /// heading is what puts *its* point where the device is facing. Zero unless
    /// heading-follow is on: a needle spinning while the map stays north-up would
    /// be the map lying twice over.
    private var tint: Color {
        switch location.status {
        case .located: .accentColor
        case .denied, .unavailable: .secondary
        case .locating: .accentColor
        case .idle: .primary
        }
    }

    /// What the tap will do next, read from the cycle rather than from the
    /// fix: the fault states still speak for themselves, a fix in flight still
    /// says it is finding you, and otherwise the label is the step the cycle is
    /// about to take — *my location* from nothing, *direction of travel* from
    /// there, *north* from orientation.
    private var label: String {
        switch location.status {
        case .denied: return "Location access is off. Enable it in Settings to use this."
        case .unavailable(let message): return message
        case .locating: return "Finding your location"
        case .idle, .located: break
        }
        switch location.followMode {
        case .nothing: return "Show my location"
        case .myLocation: return "Face my direction of travel"
        case .orientation: return "Face north"
        }
    }
}
