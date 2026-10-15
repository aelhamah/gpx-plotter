import ActivityKit
import Foundation
import RouteKit

/// Owns the app's one Live Activity, from asking for it to taking it down.
///
/// Everything here is optional in the sense that a user can switch Live
/// Activities off entirely, or that iOS can refuse an update, and neither is a
/// reason to interrupt a hike. So failures are swallowed on purpose: navigation
/// works with the activity and without it.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<HikeActivityAttributes>?
    /// Whether a hike has an activity, *or is in the middle of asking for one*.
    ///
    /// Set before the request rather than after it, because `onAppear` can run
    /// twice within the same run loop: the second call would otherwise see no
    /// activity yet, ask for a second one, and end the first — two lock screens'
    /// worth of flicker for one hike.
    private var isActive = false
    private var lastState: HikeActivityAttributes.ContentState?
    private var lastUpdateAt: Date?

    /// How stale the activity is allowed to get before iOS greys it out. A
    /// hiker who locks the phone and loses the stream should see that the numbers
    /// stopped moving rather than a confident readout that is minutes old.
    private let staleAfter: TimeInterval = 60
    /// The shortest gap between two updates.
    ///
    /// Fixes arrive about once a second, so this is really about not asking twice
    /// for the same walk: iOS budgets activity updates, and the ones it drops are
    /// dropped silently, which looks like the activity randomly lagging.
    private let minimumUpdateInterval: TimeInterval = 1

    /// Whether the user has Live Activities switched on at all.
    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var isRunning: Bool { isActive }

    // MARK: - Lifecycle

    /// Put the activity up for a hike that is starting.
    ///
    /// One hike, one activity: a second request while one is live or being asked
    /// for is ignored. Two countdowns on the lock screen would be worse than
    /// missing one, and the only way to get two is the double `onAppear`.
    func start(
        routeName: String,
        totalDistance: Double,
        startedAt: Date,
        unitSystem: UnitSystem
    ) async {
        guard isEnabled, !isActive else { return }
        isActive = true
        defer { if activity == nil { isActive = false } }

        let attributes = HikeActivityAttributes(
            routeName: routeName,
            totalDistance: totalDistance,
            startedAt: startedAt,
            unitSystem: unitSystem
        )
        do {
            // `.token`, i.e. no push: updates come from the app's own location
            // stream while it is alive, which is the only case this app is in.
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: .empty, staleDate: nil),
                pushType: nil
            )
            lastState = nil
            lastUpdateAt = nil
        } catch {
            activity = nil
        }
    }

    /// Push the current readout, if it is worth the budget.
    func update(_ state: HikeActivityAttributes.ContentState) async {
        guard let activity else { return }
        let now = Date()

        // An off-course change is the one update worth breaking the interval for:
        // it is the moment the hiker most needs to know, and it happens rarely.
        let offCourseChanged = state.isOffCourse != (lastState?.isOffCourse ?? false)
        if !offCourseChanged, let lastUpdateAt, now.timeIntervalSince(lastUpdateAt) < minimumUpdateInterval {
            return
        }

        lastState = state
        lastUpdateAt = now
        await ActivityHandle(activity).update(
            ActivityContent(state: state, staleDate: now.addingTimeInterval(staleAfter))
        )
    }

    /// Take the activity down.
    ///
    /// - Parameter dismissal: `.immediate` when the user ends it, `.after` when
    ///   the hike finished on its own, so the lock screen can show the total for a
    ///   moment instead of vanishing mid-glance.
    /// End the hike with a known final state.
    ///
    /// Separate from `end(dismissal:)` because the arrival fix is often the one
    /// update the throttle drops, and then the activity would sit on the lock
    /// screen showing the distance from *before* the last leg — 2.68 mi to go on
    /// a hike that has just finished is worse than no activity at all. The final
    /// state goes in the end content, which is what stays up during the linger.
    func finish(_ state: HikeActivityAttributes.ContentState, dismissal: ActivityUIDismissalPolicy) async {
        guard let activity else { return }
        lastState = state
        self.activity = nil
        isActive = false
        lastUpdateAt = nil
        await ActivityHandle(activity).end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: dismissal
        )
    }

    /// Take the activity down as-is.
    func end(dismissal: ActivityUIDismissalPolicy) async {
        guard let activity else { return }
        // Read the last state before dropping it: the activity's final content is
        // what stays on the lock screen for a moment, so handing it `.empty` would
        // blank the hike's total to zero at the exact moment it finished.
        let final = ActivityContent(state: lastState ?? .empty, staleDate: nil)
        self.activity = nil
        isActive = false
        lastState = nil
        lastUpdateAt = nil
        await ActivityHandle(activity).end(final, dismissalPolicy: dismissal)
    }
}

extension HikeActivityAttributes.ContentState {
    /// A valid state to open an activity with, before the first fix arrives.
    ///
    /// The activity is requested the moment navigation starts, which can be a
    /// moment before the location manager hands over anything, and ActivityKit
    /// wants content rather than nothing.
    static let empty = HikeActivityAttributes.ContentState(
        distanceAlong: 0,
        remaining: 0,
        currentElevation: nil,
        gradeAheadPercent: nil,
        nextWaypointName: nil,
        isOffCourse: false,
        offCourseMeters: 0,
        isPaused: false,
        hasArrived: false
    )
}