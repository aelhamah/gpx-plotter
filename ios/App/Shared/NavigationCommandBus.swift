import Foundation

/// Something the Live Activity asked the app to do.
///
/// The buttons on the lock screen and in the Dynamic Island are App Intents, and
/// those declared `LiveActivityIntent` run *in the app's process* — which is the
/// only reason this works at all without an App Group. That is the difference
/// between `LiveActivityIntent` and plain `AppIntent`: the latter runs in the
/// extension's own process, where there is no navigation session to talk to.
enum NavigationCommand: Equatable {
    /// Stop tracking but leave the activity up, so the hiker can see that the
    /// numbers are deliberately frozen rather than stale.
    case pause
    case resume
    /// The hike is over: stop tracking and take the activity down.
    case end
}

/// How the nav screen hears about those commands.
///
/// One slot rather than a queue. A command is not a fact about the hike, it is a
/// press, and the screen takes the slot as it handles it — so pressing pause
/// twice is two presses, and a command that arrives with nothing to act on (the
/// app was relaunched to run the intent, so there is no session on screen) simply
/// goes away rather than queueing up for a screen that will never come.
@MainActor
final class NavigationCommandBus: ObservableObject {
    static let shared = NavigationCommandBus()

    /// The command waiting to be handled, or nil when there is none.
    @Published private(set) var pending: NavigationCommand?

    /// Whether a navigation session is on screen and listening.
    ///
    /// Set by the nav screen as it appears and disappears. A Live Activity
    /// outlives the app that asked for it, so a press can arrive with nothing
    /// behind it, and the handler needs to be able to tell.
    private(set) var isObserved = false

    private init() {}

    func setObserved(_ observed: Bool) {
        isObserved = observed
    }

    /// Post a command and take the slot, so it is delivered once and once only.
    func send(_ command: NavigationCommand) {
        pending = command
    }

    /// Called by the nav screen once it has acted, so the same press cannot be
    /// handled twice by a later re-render.
    func clear() {
        pending = nil
    }
}