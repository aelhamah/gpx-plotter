import AppIntents

/// Pause, resume, and end, from the lock screen or the Dynamic Island.
///
/// Each conforms to `LiveActivityIntent`, which is the whole trick: iOS runs
/// those in the *app's* process, so the press can reach the navigation session
/// that is sitting behind a `fullScreenCover` on a suspended app. A plain
/// `AppIntent` would run here, in the extension, where there is no session and
/// no location stream to touch.
struct PauseNavigationIntent: LiveActivityIntent {
    // `let`, not `var`: the protocol only needs a getter, and Swift 6's strict
    // concurrency reads a mutable static as shared state it cannot prove safe.
    static let title: LocalizedStringResource = "Pause navigation"

    func perform() async throws -> some IntentResult {
        await LiveActivityCommandHandler.perform(.pause)
        return .result()
    }
}

struct ResumeNavigationIntent: LiveActivityIntent {
    // `let`, not `var`: the protocol only needs a getter, and Swift 6's strict
    // concurrency reads a mutable static as shared state it cannot prove safe.
    static let title: LocalizedStringResource = "Resume navigation"

    func perform() async throws -> some IntentResult {
        await LiveActivityCommandHandler.perform(.resume)
        return .result()
    }
}

struct EndNavigationIntent: LiveActivityIntent {
    // `let`, not `var`: the protocol only needs a getter, and Swift 6's strict
    // concurrency reads a mutable static as shared state it cannot prove safe.
    static let title: LocalizedStringResource = "End navigation"

    func perform() async throws -> some IntentResult {
        await LiveActivityCommandHandler.perform(.end)
        return .result()
    }
}