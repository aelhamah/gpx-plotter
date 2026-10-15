import ActivityKit
import Foundation

/// A way to call `Activity`'s async methods without tripping strict concurrency.
///
/// `Activity` is a class and is not `Sendable`, so passing one from isolated code
/// into `update(_:)` or `end(_:dismissalPolicy:)` — both async and non-isolated —
/// is a "sending risks data races" error. The unsafety is vouched for here, in one
/// place, and it is a real guarantee rather than a shrug: an `Activity` is a
/// handle onto an object ActivityKit owns, every method on it is documented as
/// safe from any thread, and the only instance in play is driven from one place at
/// a time.
struct ActivityHandle: @unchecked Sendable {
    private let activity: Activity<HikeActivityAttributes>

    init(_ activity: Activity<HikeActivityAttributes>) {
        self.activity = activity
    }

    func update(_ content: ActivityContent<HikeActivityAttributes.ContentState>) async {
        await activity.update(content)
    }

    func end(
        _ content: ActivityContent<HikeActivityAttributes.ContentState>?,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        await activity.end(content, dismissalPolicy: dismissalPolicy)
    }
}

/// The widget side of a lock-screen press.
///
/// This lives in the shared target because it needs to know something only this
/// file knows: whether a navigation session is actually on screen in the app. The
/// intents run in the app's process, so posting a command is usually enough — but
/// not always.
enum LiveActivityCommandHandler {
    /// Carry out a command from the lock screen or the Dynamic Island.
    ///
    /// The awkward case is an activity with nobody behind it. iOS keeps a Live
    /// Activity alive when the app is terminated, and this app can be terminated
    /// mid-hike (iOS reclaiming memory, the user swiping it away) without
    /// `onDisappear` ever running. The activity then sits on the lock screen
    /// counting down a hike that stopped minutes ago, and its buttons post
    /// commands to a nav screen that is not there. So: end presses end the
    /// activity directly, and pause or resume with nothing listening take the
    /// activity down rather than leave it pretending.
    static func perform(_ command: NavigationCommand) async {
        let observed = await MainActor.run { NavigationCommandBus.shared.isObserved }

        switch command {
        case .end:
            await endEveryActivity()
            await MainActor.run { NavigationCommandBus.shared.send(.end) }
        case .pause, .resume where observed:
            await MainActor.run { NavigationCommandBus.shared.send(command) }
        case .pause, .resume:
            await endEveryActivity()
        }
    }

    private static func endEveryActivity() async {
        for activity in Activity<HikeActivityAttributes>.activities {
            await ActivityHandle(activity).end(nil, dismissalPolicy: .immediate)
        }
    }
}