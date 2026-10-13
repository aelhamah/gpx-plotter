import SwiftUI
import RouteKit

/// Live guidance for one route: where you are, what's left, and whether you have
/// wandered off.
///
/// Presented as a `fullScreenCover` rather than a sheet. Guidance is looked at
/// with the phone in one hand, often in gloves, and the sheet's grabber and
/// half-height would put the important numbers behind a drag.
///
/// Everything numeric comes from `RouteProgressState` via `NavigationSession`, and
/// every number is formatted through `Units` — the same formatter the profile
/// chart uses, so the readout and the chart cannot state different distances.
struct NavigationScreen: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var location: LocationController
    @Environment(\.dismiss) private var dismiss

    @StateObject private var session: NavigationSession
    @State private var elapsed: TimeInterval = 0
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(route: Route, waypoints: [Waypoint], profile: RouteProfile) {
        _session = StateObject(wrappedValue: NavigationSession(
            route: route,
            waypoints: waypoints,
            profile: profile
        ))
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                if session.isOffCourse {
                    offCourseBanner
                }
                headline
                Spacer(minLength: 0)
                detailGrid
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal)
        }
        .onAppear {
            session.start()
            location.startStreaming()
        }
        .onDisappear {
            // Navigation owns the stream: leaving the screen must stop it, or the
            // blue background indicator stays on with nothing to show for it.
            location.stopStreaming()
        }
        .onChange(of: location.fix) { _, fix in
            guard let fix else { return }
            session.ingest(fix, speed: location.speed)
            session.runsInBackground = location.runsInBackground
        }
        .onReceive(tick) { now in
            elapsed = session.elapsed(at: now) ?? 0
        }
        .onChange(of: session.hasArrived) { _, arrived in
            if arrived { location.stopStreaming() }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.route.name)
                    .font(.headline)
                Text("\(session.readout.map { Int($0.fraction * 100) } ?? 0)% complete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("End")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Stops navigation")
        }
        .padding(.top, 8)
    }

    // MARK: - Off course

    private var offCourseBanner: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Off the route")
                    .font(.subheadline.weight(.semibold))
                Text("\(Units.formatDistance(session.readout?.offRoute ?? 0, system: workspace.unitSystem)) from the line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Readout

    /// The three numbers a hiker actually watches while walking.
    private var headline: some View {
        VStack(spacing: 4) {
            Text(session.readout?.nextWaypoint ?? session.route.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(Units.formatDistance(session.readout?.remaining ?? 0, system: workspace.unitSystem))
                .font(.system(size: 72, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            Text("remaining")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var detailGrid: some View {
        VStack(spacing: 0) {
            detail("Elevation", Units.formatElevation(session.readout?.elevation, system: workspace.unitSystem))
            Divider()
            detail("Grade ahead", gradeAheadText)
            Divider()
            detail("Elapsed", elapsedText)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .fontWeight(.medium)
        }
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    /// Grade as a climb-or-descend arrow, because "8%" on its own does not say
    /// whether the hill is going up.
    ///
    /// `gradeAheadPercent` is a rise-over-run *percentage*, while the arrow bands
    /// and `Units.formatSlope` both want degrees, so it converts rather than
    /// labelling a percentage with a degree sign.
    private var gradeAheadText: String {
        guard let grade = session.readout?.gradeAhead else { return Units.missingValue }
        let degrees = atan(grade / 100) * 180 / .pi
        let arrow = degrees > 1 ? "▲" : (degrees < -1 ? "▼" : "▬")
        return "\(arrow)  \(Units.formatSlope(degrees))"
    }

    private var elapsedText: String {
        guard elapsed > 0 else { return Units.missingValue }
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 8) {
            if session.hasArrived {
                Label("You have arrived", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            }
            // Saying this plainly matters: without "Always", iOS stops delivering
            // fixes when the screen locks, and the readout silently freezes part
            // way up a hill while the blue indicator is still on.
            if !session.runsInBackground && location.status != .denied {
                Button("Keep tracking with the screen locked") {
                    location.requestBackgroundAuthorization()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if location.status == .denied {
                Label(
                    "Location is off, so progress cannot be tracked. Enable it in Settings.",
                    systemImage: "location.slash"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.bottom, 12)
    }
}