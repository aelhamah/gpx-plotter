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

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Ask for permission and start a one-shot fix.
    func locate() {
        switch manager.authorizationStatus {
        case .notDetermined:
            status = .locating
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = .denied
        case .authorizedWhenInUse, .authorizedAlways:
            status = .locating
            manager.requestLocation()
        @unknown default:
            status = .unavailable("Location services are unavailable.")
        }
    }

    /// Stop updating, e.g. when the map is torn down.
    func stop() {
        manager.stopUpdatingLocation()
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
        let fix = LocationFix(
            lon: location.coordinate.longitude,
            lat: location.coordinate.latitude,
            accuracyMeters: max(location.horizontalAccuracy, 0)
        )
        Task { @MainActor in
            self.fix = fix
            self.status = .located
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.handle(error)
        }
    }
}
