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
    /// Paused from the lock screen or the Dynamic Island. Tracking is stopped and
    /// the last fix stays on the map, so the screen has to say so rather than
    /// look frozen.
    @State private var isPaused = false
    /// Heading-follow was defaulted on for this navigation, so leaving the screen
    /// can put it back the way it was rather than stranding the viewer on a
    /// heading-up map they did not ask for.
    @State private var followsHeadingDefaulted = false

    /// The hike is over, as opposed to this view going away.
    ///
    /// The distinction is the whole of #71. `onDisappear` fires when MapLibre
    /// re-attaches, so it cannot be the signal to end a Live Activity — but it
    /// is also the only thing that happens when the in-app End button is tapped,
    /// and with nothing else ending it the activity outlived every hike and
    /// `isActive` stayed true, so the next navigation could never even replace
    /// it. So: end where the hike actually ends, and use this to stop
    /// `onDisappear` ending a hike that is still going.
    @State private var hasEnded = false

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
            // Facing the direction of travel, which is the point of navigating:
            // the map was north-up because `followsHeading` lived on the locate
            // button, and that button is not on this screen, so there was no way
            // to reach it from here at all. Reset rather than assign, so coming
            // back from the viewer with it turned off does not quietly re-enable
            // a mode the user turned off there.
            location.followsHeading = true
            followsHeadingDefaulted = true
            // Navigation is the one moment the "Always" prompt has context: the
            // user has just chosen to walk a route, and it is the only
            // authorisation that keeps the readout running with the phone in a
            // pocket. Declared in the plist and never asked for, the capability
            // is unreachable, and the warning below would be permanent.
            location.requestBackgroundAuthorization()
            // A fix that arrived before this screen did still counts. Without
            // this the readout is empty -- no distance, no elevation, no dot's
            // distance along the route -- until the *next* fix, which on a
            // stationary simulator can be a long time coming.
            ingest(location.fix)
            startActivity()
            NavigationCommandBus.shared.setObserved(true)
        }
        .onDisappear {
            // Navigation owns the stream: leaving the screen must stop it, or the
            // blue background indicator stays on with nothing to show for it.
            location.stopStreaming()
            NavigationCommandBus.shared.setObserved(false)
            // Only undo the default: a compass tapped here is a choice, and
            // re-setting it on the way out would discard it.
            if followsHeadingDefaulted {
                location.followsHeading = false
                followsHeadingDefaulted = false
            }
            // Ending here unconditionally was the first attempt and it is wrong:
            // this view is torn down and rebuilt when MapLibre re-attaches, which
            // is why `onAppear` already runs twice, and that took the activity
            // down about 15s into a walk. So the end lives in `endNavigation()`,
            // which both the button and the lock screen call, and this only
            // catches the case where the hike is genuinely over — arrival, or the
            // user ending it and the dismissal landing before the end call.
            // An app iOS kills leaves the activity up, the way a run does when
            // your phone dies, which is the behaviour we want there.
            if hasEnded {
                Task { await LiveActivityController.shared.end(dismissal: .immediate) }
            }
        }
        .onChange(of: location.fix) { _, fix in
            ingest(fix)
        }
        .onReceive(NavigationCommandBus.shared.$pending) { command in
            guard let command else { return }
            handle(command)
            NavigationCommandBus.shared.clear()
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
            guard arrived else { return }
            hasEnded = true
            location.stopStreaming()
            // Lingers briefly rather than vanishing: the arrival is the one thing
            // worth seeing on the lock screen after the hike.
            // The readout may in principle be absent if the session was ended
            // without ever taking a fix; the activity's own last state is then the
            // honest thing to end on.
            let finalState = session.readout.map { state($0, isPaused: false) }
            Task {
                if let finalState {
                    await LiveActivityController.shared.finish(
                        finalState,
                        dismissal: .after(.now.addingTimeInterval(30))
                    )
                } else {
                    await LiveActivityController.shared.end(dismissal: .after(.now.addingTimeInterval(30)))
                }
            }
        }
    }

    // MARK: - Live Activity

    /// Put the lock-screen activity up for this hike.
    ///
    /// Needs the route's own length rather than the remaining distance, because
    /// the progress bar has to know how far along the whole route this is.
    private func startActivity() {
        // Idempotent, because `onAppear` runs more than once: without this the
        // second run ends the activity the first one just requested and asks
        // iOS for another, which flickers the lock screen on every map re-attach.
        guard !LiveActivityController.shared.isRunning else { return }
        Task {
            await LiveActivityController.shared.start(
                routeName: session.route.name,
                totalDistance: session.totalDistance,
                startedAt: session.startedAt ?? Date(),
                unitSystem: workspace.unitSystem
            )
            // Start with whatever is already known, so the activity does not sit
            // on a row of dashes until the second fix arrives.
            if let readout = session.readout { await updateActivity(readout, isPaused: false) }
        }
    }

    private func updateActivity(
        _ readout: NavigationSession.Readout,
        isPaused: Bool,
        immediately: Bool = false
    ) async {
        await LiveActivityController.shared.update(
            state(readout, isPaused: isPaused),
            immediately: immediately
        )
    }

    /// The activity's state for a readout. The lock screen's numbers are the nav
    /// screen's numbers, read in a different process — which only works if there
    /// is exactly one translation between them.
    private func state(_ readout: NavigationSession.Readout, isPaused: Bool) -> HikeActivityAttributes.ContentState {
        HikeActivityAttributes.ContentState(
            distanceAlong: readout.covered,
            remaining: readout.remaining,
            currentElevation: readout.elevation,
            gradeAheadPercent: readout.gradeAhead,
            nextWaypointName: readout.nextWaypoint,
            isOffCourse: session.isOffCourse,
            offCourseMeters: readout.offRoute,
            isPaused: isPaused,
            hasArrived: session.hasArrived,
            hasFix: true
        )
    }

    /// A press on the lock screen or in the Dynamic Island.
    ///
    /// The intents run in this process, which is the only reason this arrives at
    /// all — see `NavigationCommandBus`. A resume with no session behind it means
    /// the app was relaunched to run the intent, so there is nothing to resume and
    /// the activity goes down instead of lying about a hike that is not running.
    private func handle(_ command: NavigationCommand) {
        switch command {
        case .pause:
            location.stopStreaming()
            isPaused = true
            // Immediately: a pause the lock screen does not show is a pause the
            // hiker cannot confirm, and the tile would keep offering "Pause"
            // forever.
            Task { if let readout = session.readout { await updateActivity(readout, isPaused: true, immediately: true) } }
        case .resume:
            location.startStreaming()
            isPaused = false
            Task { if let readout = session.readout { await updateActivity(readout, isPaused: false, immediately: true) } }
        case .end:
            endNavigation()
        }
    }

    /// End the hike: stop tracking, take the activity down, leave.
    ///
    /// The single place a hike ends, so the button, the lock screen and
    /// `onDisappear` cannot disagree about whether it has. Ending used to be a
    /// `dismiss()` on the button and nothing at all on the lock screen, which is
    /// how an activity outlived the hike and left `isActive` set — and that in
    /// turn blocked the *next* navigation from ever starting one.
    private func endNavigation() {
        guard !hasEnded else { return }
        hasEnded = true
        location.stopStreaming()
        Task { await LiveActivityController.shared.end(dismissal: .immediate) }
        dismiss()
    }

    /// Fold a fix into the session and mirror it onto the map. The covered
    /// distance is a separate `@State` because `MapView` binds it rather than
    /// reading the session, and reading it from the session would mean either a
    /// second source of truth or reworking the viewer's binding.
    private func ingest(_ fix: LocationFix?) {
        guard let fix else { return }
        session.ingest(fix, speed: location.speed)
        session.runsInBackground = location.runsInBackground
        coveredDistance = session.readout?.covered
        if let readout = session.readout {
            let paused = isPaused
            Task { await updateActivity(readout, isPaused: paused) }
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

            if footerMessage != nil || hasArrived || canRequestBackground {
                Divider()
                HStack(spacing: 8) {
                    if hasArrived {
                        Label("Arrived", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if let footerMessage {
                        Text(footerMessage).foregroundStyle(.secondary)
                    }
                    // The prompt on entering navigation is easy to miss, and
                    // nothing else in the UI would ever ask again.
                    if canRequestBackground {
                        Button("Turn on") { location.requestBackgroundAuthorization() }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
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
        if isPaused {
            // The lock screen says this too. One truth about why the numbers have
            // stopped matters more than brevity.
            return "Paused — tracking is stopped until you resume."
        }
        if !session.runsInBackground && location.status != .denied {
            // Saying this plainly matters: without "Always", iOS stops delivering
            // fixes when the screen locks, and the readout silently freezes part
            // way up a hill while the blue indicator is still on.
            return "Background tracking is off — the readout will stop when the screen locks."
        }
        return nil
    }

    /// Whether the "Always" prompt is still on the table, i.e. when-in-use is
    /// granted and the app has not already asked. Read from the controller
    /// rather than derived here so it stops being offered the moment iOS stops
    /// showing it.
    private var canRequestBackground: Bool { location.canRequestBackground }

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
                // A viewfinder says "the camera is tracking me", which is the
                // question this button answers; `location.fill` said "where I
                // am", which is the dot on the map underneath it and nothing to
                // do with following. `hand.raised` rather than `hand.tap` because
                // it is a mode you are in, not a gesture being made.
                Label(followsUser ? "Following" : "Pan freely", systemImage: followsUser ? "viewfinder.circle.fill" : "hand.raised.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                // Same two states as the viewer's locate button: facing the way
                // you are going, or facing north. A third tap is back where it
                // started, which is the compass behaviour people already expect.
                location.toggleHeading()
                // The button is a choice now, so it is no longer the default we
                // put there. Without this the exit code below reads the flag as
                // "we set this" and switches it back off anyway, discarding what
                // the user just did -- the exact thing the flag exists to
                // prevent, one tap later.
                followsHeadingDefaulted = false
            } label: {
                // The same needle as the locate button, and it really turns.
                // A static `location.north.line.fill` here claimed the map was
                // pointing north when it was not -- the one thing on this screen
                // whose whole purpose is to say where the map is pointing.
                Label {
                    Text("North")
                } icon: {
                    CompassNeedle(alwaysNeedle: true)
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(location.followsHeading ? "Face north" : "Face my direction of travel")

            // Ends through `endNavigation()` rather than a bare `dismiss()`, so the
            // Live Activity is taken down on the same tap. See `onDisappear`.
            Button("End") { endNavigation() }
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
