import Foundation

/// Off-course state machine, per docs/ios-plan.md §7.
///
/// The hysteresis gap is deliberate: enter above 40 m sustained for 8 s, clear
/// below 25 m sustained for 5 s. Without it a hiker oscillating around the
/// threshold would retrigger the alert on every tick.
///
/// Fixes are gated on accuracy and speed, which kills standing-start GPS wander
/// — the main source of false positives. The first seconds after starting are
/// ignored while the fix settles.
///
/// The clock is injected so the timing rules can be tested without waiting.
public struct OffCourseDetector: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// Navigating, on or near the route.
        case onCourse
        /// Navigating, off the route since the given date.
        case offCourse(since: Date)
    }

    public struct Configuration: Sendable {
        /// Ignore fixes with worse horizontal accuracy than this.
        public var maxAccuracyMeters: Double = 30
        /// Ignore fixes slower than this — standing still is not navigating.
        public var minSpeedMetersPerSecond: Double = 0.5
        /// Lateral distance that counts as off course.
        public var enterThresholdMeters: Double = 40
        /// How long it must stay above `enterThresholdMeters` before alerting.
        public var enterDuration: TimeInterval = 8
        /// Lateral distance that clears the alert.
        public var clearThresholdMeters: Double = 25
        /// How long it must stay below `clearThresholdMeters` before clearing.
        public var clearDuration: TimeInterval = 5
        /// Settling period after starting, during which nothing can trigger.
        public var settlingDuration: TimeInterval = 15

        public init() {}
    }

    public private(set) var state: State = .idle

    private let configuration: Configuration
    private var startedAt: Date?
    private var aboveThresholdSince: Date?
    private var belowThresholdSince: Date?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Begin navigation. Resets any previous session's state.
    public mutating func start(at date: Date) {
        startedAt = date
        state = .onCourse
        aboveThresholdSince = nil
        belowThresholdSince = nil
    }

    /// Feed a position fix and get the resulting state.
    ///
    /// - Parameters:
    ///   - offCourseMeters: lateral distance from the route line.
    ///   - accuracyMeters: horizontal accuracy reported by CoreLocation.
    ///   - speedMetersPerSecond: ground speed; fixes below the gate are ignored.
    ///   - date: the fix's timestamp, used for all timing.
    @discardableResult
    public mutating func update(
        offCourseMeters: Double,
        accuracyMeters: Double,
        speedMetersPerSecond: Double,
        at date: Date
    ) -> State {
        guard let startedAt else { return state }
        guard date.timeIntervalSince(startedAt) >= configuration.settlingDuration else {
            return state
        }
        guard accuracyMeters < configuration.maxAccuracyMeters,
              speedMetersPerSecond > configuration.minSpeedMetersPerSecond
        else {
            // Unreliable fix: hold the current state rather than letting a
            // dropout count as "back on route".
            return state
        }

        switch state {
        case .idle:
            state = .onCourse

        case .onCourse:
            if offCourseMeters > configuration.enterThresholdMeters {
                let since = aboveThresholdSince ?? date
                aboveThresholdSince = since
                if date.timeIntervalSince(since) >= configuration.enterDuration {
                    state = .offCourse(since: date)
                    belowThresholdSince = nil
                }
            } else {
                aboveThresholdSince = nil
            }

        case .offCourse:
            if offCourseMeters < configuration.clearThresholdMeters {
                let since = belowThresholdSince ?? date
                belowThresholdSince = since
                if date.timeIntervalSince(since) >= configuration.clearDuration {
                    state = .onCourse
                    aboveThresholdSince = nil
                }
            } else {
                belowThresholdSince = nil
            }
        }

        return state
    }

    /// Stop navigation and clear state.
    public mutating func reset() {
        state = .idle
        startedAt = nil
        aboveThresholdSince = nil
        belowThresholdSince = nil
    }

    /// Whether the alert should currently be showing.
    public var isOffCourse: Bool {
        if case .offCourse = state { return true }
        return false
    }
}
