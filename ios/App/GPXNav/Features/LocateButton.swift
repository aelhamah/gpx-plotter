import SwiftUI
import CoreLocation
import RouteKit

/// The map's locate button, with the same states the web app's `locate.ts`
/// distinguishes: locating, located, permission refused, and unavailable.
struct LocateButton: View {
    @EnvironmentObject private var location: LocationController

    var body: some View {
        Button {
            location.locate()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .shadow(radius: 2, y: 1)
        }
        .accessibilityLabel(label)
        .accessibilityHint(label)
    }

    private var symbol: String {
        switch location.status {
        case .located: "location.fill"
        case .locating: "location.circle"
        case .denied: "location.slash"
        case .unavailable: "location.slash"
        case .idle: "location"
        }
    }

    private var tint: Color {
        switch location.status {
        case .located: .accentColor
        case .denied, .unavailable: .secondary
        case .locating: .accentColor
        case .idle: .primary
        }
    }

    private var label: String {
        switch location.status {
        case .idle: "Show my location"
        case .locating: "Finding your location"
        case .located: "Centre on your location"
        case .denied: "Location access is off. Enable it in Settings to use this."
        case .unavailable(let message): message
        }
    }
}
