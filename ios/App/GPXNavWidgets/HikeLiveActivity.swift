import ActivityKit
import RouteKit
import SwiftUI
import WidgetKit

/// The lock screen and Dynamic Island presentation of a hike.
///
/// Everything is read from `context.state` and `context.attributes`, so this
/// target holds no navigation state of its own and needs nothing from the app at
/// runtime: the activity carries the whole readout.
struct HikeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HikeActivityAttributes.self) { context in
            LockScreenHike(context: context)
                .activityBackgroundTint(Color.black.opacity(0.4))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(waypointLabel(context))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(headline(context))
                            .font(.headline)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Units.formatElevation(context.state.currentElevation, system: context.attributes.unitSystem))
                            .font(.headline)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        if let grade = HikeFormat.grade(context.state.gradeAheadPercent) {
                            Text(grade)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.routeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        HikeProgressBar(progress: progress(context))
                        // The plan has promised Pause and End in the island since
                        // it was written, and only the lock screen ever had them.
                        // A hiker who swipes down to the island to read the
                        // remaining distance cannot end the hike from there, and
                        // has to unlock the phone to do it.
                        if !context.state.hasArrived {
                            HikeControls(isPaused: context.state.isPaused)
                        }
                    }
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                // Was `isOffCourse ? ... : "figure.hiking"`, so a paused hike and
                // a finished one showed a walking figure here while `minimal` and
                // the lock screen showed a pause or a tick for the same state.
                Image(systemName: symbolName(for: context))
                    .foregroundStyle(tint(for: context))
            } compactTrailing: {
                Text(headline(context))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(context.state.hasArrived ? .green : offCourse(context) ? .orange : .primary)
            } minimal: {
                Image(systemName: symbolName(for: context))
                    .foregroundStyle(tint(for: context))
            }
            // The keyline is the first thing that reads when the island is
            // otherwise a strip of numbers, so it carries the state.
            .keylineTint(tint(for: context))
        }
    }

    // MARK: - Shared bits

    private func offCourse(_ context: ActivityViewContext<HikeActivityAttributes>) -> Bool {
        context.state.isOffCourse
    }

    /// Glyph and colour for the whole activity, shared by the island's three
    /// presentations so they cannot disagree about what state the hike is in.
    private func symbolName(for context: ActivityViewContext<HikeActivityAttributes>) -> String {
        if context.state.hasArrived { return "checkmark.circle.fill" }
        if context.state.isOffCourse { return "exclamationmark.triangle.fill" }
        if context.state.isPaused { return "pause.circle.fill" }
        return "figure.hiking"
    }

    private func tint(for context: ActivityViewContext<HikeActivityAttributes>) -> Color {
        if context.state.hasArrived { return .green }
        if context.state.isOffCourse { return .orange }
        return .cyan
    }

    /// 0...1 along the route. Zero when the route has no length, rather than a
    /// NaN progress bar.
    private func progress(_ context: ActivityViewContext<HikeActivityAttributes>) -> Double {
        let total = context.attributes.totalDistance
        guard total > 0 else { return 0 }
        return min(max(context.state.distanceAlong / total, 0), 1)
    }

    private func waypointLabel(_ context: ActivityViewContext<HikeActivityAttributes>) -> String {
        context.state.nextWaypointName ?? context.attributes.routeName
    }

    /// What the distance slot says, for every surface.
    ///
    /// One function because this string was computed three ways and only one of
    /// them knew about arriving. "—" before the first fix: the activity is
    /// requested when navigation starts, which can be a moment before the location
    /// manager answers, and until then the honest reading is "not yet", not
    /// "0.00 mi left".
    private func headline(_ context: ActivityViewContext<HikeActivityAttributes>) -> String {
        if context.state.hasArrived { return "Arrived" }
        guard context.state.hasFix else { return "—" }
        return Units.formatDistance(context.state.remaining, system: context.attributes.unitSystem)
    }
}

/// The lock screen face: the same figures as the nav screen's HUD, plus the
/// elapsed clock and the two buttons.
private struct LockScreenHike: View {
    let context: ActivityViewContext<HikeActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(headline)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(stateColor)
                }
                Spacer(minLength: 0)
                if let grade = HikeFormat.grade(context.state.gradeAheadPercent) {
                    Text(grade)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                // Counting up from when navigation started. `.timer` keeps ticking
                // on the lock screen without an update per second from the app.
                Text(context.attributes.startedAt, style: .timer)
                    .font(.subheadline)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }

            HikeProgressBar(progress: progress)

            if context.state.hasArrived {
                Label("Arrived", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else if context.state.isOffCourse {
                Label(
                    "Off the route · \(Units.formatDistance(context.state.offCourseMeters, system: system))",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            } else if context.state.isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            // Hidden once arrived: the hike is over, and a Pause button that
            // stops an already-stopped stream while appearing to do nothing is
            // worse than no button.
            if !context.state.hasArrived {
                HikeControls(isPaused: context.state.isPaused)
            }
        }
        .padding(14)
    }

    private var system: UnitSystem { context.attributes.unitSystem }

    private var label: String {
        context.state.nextWaypointName ?? context.attributes.routeName
    }

    /// What the big number says. Same three cases as the island's, kept as one
    /// function each so a change to one does not silently miss the other.
    private var headline: String {
        if context.state.hasArrived { return "Arrived" }
        guard context.state.hasFix else { return "—" }
        return Units.formatDistance(context.state.remaining, system: system)
    }

    private var stateColor: Color {
        if context.state.hasArrived { return .green }
        if context.state.isOffCourse { return .orange }
        return context.state.isPaused ? .secondary : .primary
    }

    private var progress: Double {
        let total = context.attributes.totalDistance
        guard total > 0 else { return 0 }
        return min(max(context.state.distanceAlong / total, 0), 1)
    }
}

/// Pause / Resume and End, on whichever surface is asking.
///
/// A view rather than duplicated button rows, because the two surfaces drifting
/// apart is exactly what already went wrong with the state glyphs: the lock
/// screen grew controls and the island never did.
struct HikeControls: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isPaused {
                Button(intent: ResumeNavigationIntent()) {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
            } else {
                Button(intent: PauseNavigationIntent()) {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
            Button(intent: EndNavigationIntent()) {
                Label("End", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .font(.caption.weight(.semibold))
    }
}

/// The progress bar, shared by the lock screen and the island's bottom.
///
/// A plain `ProgressView` cannot be tinted to match the map's trace on a lock
/// screen background, and a capsule two rects wide is all this needs to be.
private struct HikeProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule()
                    .fill(progressColor)
                    .frame(width: max(4, geometry.size.width * progress))
            }
        }
        .frame(height: 5)
    }

    private var progressColor: Color { .cyan }
}