import CoreLocation
import Foundation
import RouteKit

/// Location for the map's blue dot, wrapped so SwiftUI can observe it.
///
/// The web app's `locate.ts` also has to explain itself when permission is
/// refused or the page is insecure; the same states are surfaced here because
/// the button has to say something useful rather than silently do nothing.
@MainActor
final class LocationController: NSObject, ObservableObject {
    enum Status: Equatable {
        case idle
        case locating
        case located
        case denied
        case unavailable(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var fix: LocationFix?
    /// Direction of travel in degrees, true-north based, or nil before the
    /// first heading. Drives the map's rotation when the locate button is used.
    @Published private(set) var heading: CLLocationDirection?
    /// Ground speed of the last fix, metres per second. Zero when unknown.
    ///
    /// `OffCourseDetector` ignores fixes below a walking pace, because standing
    /// still makes GPS wander sideways and wander is what a naive off-course
    /// check reads as a wrong turn.
    @Published private(set) var speed: CLLocationSpeed = 0
    /// True while fixes are streaming rather than one-shot requested.
    @Published private(set) var isStreaming = false
    /// Whether iOS will keep delivering fixes with the screen locked.
    ///
    /// Only ever true with "Always" authorisation — the plist declares both
    /// usage descriptions and `UIBackgroundModes: location`, but when-in-use
    /// stops the stream at background. The nav screen says so rather than
    /// pretending the hike is still being tracked.
    @Published private(set) var runsInBackground = false

    /// Whether iOS would still show the "Always" prompt if asked.
    ///
    /// True only under when-in-use authorisation. Once Always is granted the
    /// prompt can never appear again, and after the user has refused it iOS
    /// stops offering it, so this goes false rather than leaving the nav screen
    /// advertising a button that would do nothing.
    @Published private(set) var canRequestBackground = false

    /// Whether the map is currently following the direction of travel. Tapping
    /// locate again snaps back to north, the way a compass button behaves.
    @Published var followsHeading = false

    /// Set when the user has asked to be moved to their position, and cleared once
    /// the map has done it.
    ///
    /// A one-shot request rather than a standing "follow me" mode, because the
    /// camera must not chase every fix: navigation streams fixes continuously, so
    /// re-centring on each one would drag the map out from under anyone trying to
    /// look at something else. Matches the web app's `locate.ts`, which eases to
    /// the fix once and then leaves the camera alone.
    private var recentreRequested = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // Needed for the compass behaviour; unavailable hardware simply never
        // calls back, so `heading` stays nil and the button falls back to north.
        if CLLocationManager.headingAvailable() {
            manager.headingFilter = 5
        }
    }

    /// Ask for permission and start a one-shot fix, moving the map to it.
    func locate() {
        recentreRequested = true
        switch manager.authorizationStatus {
        case .notDetermined:
            status = .locating
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = .denied
        case .authorizedWhenInUse, .authorizedAlways:
            status = .locating
            manager.requestLocation()
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
        @unknown default:
            status = .unavailable("Location services are unavailable.")
        }
    }

    /// Stream fixes for navigation, until `stopStreaming()`.
    ///
    /// The settings differ from `locate()` in three ways that matter:
    ///
    /// - `pausesLocationUpdatesAutomatically = false`, because the default
    ///   stops updates whenever the system decides the user is stationary, which
    ///   on a switchback or at a viewpoint is exactly when progress should keep
    ///   being measured.
    /// - `activityType = .fitness`, so the blue background indicator reads as
    ///   exercise rather than a navigation app at large.
    /// - `allowsBackgroundLocationUpdates`, which only delivers anything behind
    ///   the lock screen under "Always" authorisation.
    func startStreaming() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // Ask for the stronger one directly: a hike is the case where the
            // screen locks, and asking twice reads as pestering.
            status = .locating
            manager.requestAlwaysAuthorization()
        case .denied, .restricted:
            status = .denied
        case .authorizedWhenInUse, .authorizedAlways:
            beginStreaming()
        @unknown default:
            status = .unavailable("Location services are unavailable.")
        }
    }

    private func beginStreaming() {
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        // Only honoured with "Always"; harmless otherwise, and iOS stops the
        // stream at background instead of crashing.
        manager.allowsBackgroundLocationUpdates = true
        // Five metres: a hiker's own pace does not produce useful fixes closer
        // together than this, and each one wakes the process.
        manager.distanceFilter = 5
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
        isStreaming = true
        refreshBackgroundAuthorization()
        if status == .idle { status = .locating }
    }

    /// Stop streaming fixes, e.g. when navigation ends or the map is torn down.
    func stopStreaming() {
        guard isStreaming else { return }
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        isStreaming = false
        runsInBackground = false
    }

    /// Stop updating, e.g. when the map is torn down.
    func stop() {
        stopStreaming()
    }

    /// Ask for "Always" so a hike keeps being tracked with the screen locked.
    ///
    /// Separate from `startStreaming` because iOS will only show that prompt
    /// after when-in-use has been granted, and asking for it on first launch is a
    /// request the user has no context for. The nav screen calls this when
    /// navigation starts, and again from the warning it shows while background
    /// tracking is still off.
    func requestBackgroundAuthorization() {
        guard manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.requestAlwaysAuthorization()
    }

    /// Re-read both facts about authorisation that the UI branches on: whether
    /// fixes survive a locked screen, and whether the "Always" prompt is still
    /// available. Called wherever authorisation could have changed, so neither
    /// is a guess carried over from when navigation started.
    private func refreshBackgroundAuthorization() {
        let status = manager.authorizationStatus
        runsInBackground = status == .authorizedAlways
        canRequestBackground = status == .authorizedWhenInUse
    }

    /// Cycle the map between facing the direction of travel and facing north.
    ///
    /// Also a recentre request: switching between north and the direction of
    /// travel only makes sense relative to where the user is standing.
    func toggleHeading() {
        guard heading != nil else { return }
        followsHeading.toggle()
        recentreRequested = true
    }

    /// Take the pending recentre request, if there is one.
    ///
    /// Called by the map when it is about to move the camera, so the request is
    /// spent rather than re-applied on the next state change.
    func consumeRecentreRequest() -> Bool {
        defer { recentreRequested = false }
        return recentreRequested
    }

    private func handle(_ error: Error) {
        if let clError = error as? CLError, clError.code == .denied {
            status = .denied
        } else {
            status = .unavailable(error.localizedDescription)
        }
    }
}

extension LocationController: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Read the value out here, then drive our own MainActor-isolated manager.
        // Passing the delegate's `manager` across would send a non-Sendable
        // CLLocationManager into the actor.
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.refreshBackgroundAuthorization()
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.status = .locating
                self.manager.requestLocation()
            case .denied, .restricted:
                self.status = .denied
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // The timestamp and speed both travel with the fix. `OffCourseDetector`
        // times everything off the fix's own timestamp rather than "now", so a
        // batch of fixes delivered late does not stretch its 8s window; and it
        // ignores slow fixes outright, because standing still makes GPS wander
        // sideways and wander is what a naive off-course check reads as a wrong
        // turn. `LocationFix.timestamp` otherwise defaults to the epoch.
        let fix = LocationFix(
            lon: location.coordinate.longitude,
            lat: location.coordinate.latitude,
            accuracyMeters: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : .greatestFiniteMagnitude,
            timestamp: location.timestamp
        )
        let speed = location.speed >= 0 ? location.speed : 0
        // Read the authorisation out here rather than inside the `Task`: passing
        // the delegate's non-Sendable `CLLocationManager` across the isolation
        // boundary is a data race, which is the same trap the authorisation
        // callback above documents.
        let isAlways = manager.authorizationStatus == .authorizedAlways
        Task { @MainActor in
            self.fix = fix
            self.speed = speed
            self.status = .located
            self.runsInBackground = isAlways
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // `trueHeading` is invalid until location permission is granted, so fall
        // back to the magnetic value rather than snapping the map to 0.
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard value >= 0 else { return }
        Task { @MainActor in
            self.heading = value
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.handle(error)
        }
    }
}
