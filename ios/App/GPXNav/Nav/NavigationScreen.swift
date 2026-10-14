import SwiftUI
import RouteKit

/// Live guidance for one route: the map, where you are on it, what's left, and
/// whether you have wandered off.
///
/// The map is not optional here. A readout that says "2.6 mi remaining" tells you
/// nothing about *which way* the trail goes or that you have just cut a corner;
/// the route, the dot under the crosshair, and the walked portion are what make
/// the numbers mean anything. The figures sit over the bottom of the map rather
/// than under it, so the route stays visible while they are read.
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
    /// Mirrors the session's covered distance into `MapView`, which draws it as a
    /// trace over the route. Bound because the map is a separate view.
    @State private var coveredDistance: Double?
    @State private var followsUser = true

    init(route: Route, waypoints: [Waypoint], profile: RouteProfile) {
        _session = StateObject(wrappedValue: NavigationSession(
            route: route,
            waypoints: waypoints,
            profile: profile
        ))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapView(
                route: session.route,
                // The walked portion of the route. Same mechanism the profile
                // chart's scrub uses, and it means the same thing here: how far
                // along the route you have got.
                scrubbedDistance: $coveredDistance,
                onStyleLoaded: { },
                followsUserLocation: $followsUser
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                if session.isOffCourse {
                    offCourseBanner
                }
                hud
            }
            .padding(.bottom, 8)
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
            coveredDistance = session.readout?.covered
        }
        .task {
            // The clock cannot be a `Timer.publish` stored on the view. This body
            // is evaluated again on every fix, which builds a fresh publisher and
            // resubscribes -- and with one-second fixes against a one-second
            // timer, the subscription is always torn down just before it fires, so
            // the elapsed time never leaves 0:00. A task survives re-renders.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                elapsed = session.elapsed() ?? 0
            }
        }
        .onChange(of: session.hasArrived) { _, arrived in
            if arrived { location.stopStreaming() }
        }
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
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
        }
        .foregroundStyle(.orange)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
    }

    // MARK: - HUD

    /// The figures, over the bottom of the map. Compact on purpose: this covers
    /// the route, so the map is the point.
    private var hud: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.readout?.nextWaypoint ?? session.route.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(Units.formatDistance(session.readout?.remaining ?? 0, system: workspace.unitSystem))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                statColumn("Progress", "\(Int((session.readout?.fraction ?? 0) * 100))%")
                statColumn("Elevation", Units.formatElevation(session.readout?.elevation, system: workspace.unitSystem))
                statColumn("Ahead", gradeAheadText)
                statColumn("Elapsed", elapsedText)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            if footerMessage != nil || hasArrived {
                Divider()
                HStack(spacing: 8) {
                    if hasArrived {
                        Label("Arrived", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if let footerMessage {
                        Text(footerMessage).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 10)
            }

            Divider()
            endRow
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
    }

    private var hasArrived: Bool { session.hasArrived }

    /// Only worth the row when there is something to say.
    private var footerMessage: String? {
        if location.status == .denied {
            return "Location is off, so progress cannot be tracked. Enable it in Settings."
        }
        if !session.runsInBackground && location.status != .denied {
            // Saying this plainly matters: without "Always", iOS stops delivering
            // fixes when the screen locks, and the readout silently freezes part
            // way up a hill while the blue indicator is still on.
            return "Background tracking is off — the readout will stop when the screen locks."
        }
        return nil
    }

    private func statColumn(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var endRow: some View {
        HStack(spacing: 10) {
            Button {
                // A pause-and-recentre, not just a reset: panning away to look at
                // the route ahead is the whole point of having a map here, and
                // following snaps it straight back on the next fix.
                followsUser.toggle()
            } label: {
                Label(followsUser ? "Following" : "Pan freely", systemImage: followsUser ? "location.fill" : "hand.tap")
                    .font(.caption)
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("End") { dismiss() }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Stops navigation")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
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
        return "\(arrow) \(Int(degrees.rounded()))°"
    }

    private var elapsedText: String {
        guard elapsed > 0 else { return Units.missingValue }
        let total = Int(elapsed)
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
