import SwiftUI
import CoreLocation
import RouteKit

/// The map's locate button, with the same states the web app's `locate.ts`
/// distinguishes: locating, located, permission refused, and unavailable.
struct LocateButton: View {
    @EnvironmentObject private var location: LocationController

    var body: some View {
        Button {
            // Already tracking: this tap switches between facing the direction
            // of travel and facing north, the way a compass button behaves.
            if location.fix != nil {
                location.toggleHeading()
            } else {
                location.locate()
            }
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
        if location.followsHeading, location.heading != nil {
            return "location.north.line.fill"
        }
        switch location.status {
        case .located: return "location.fill"
        case .locating: return "location.circle"
        case .denied: return "location.slash"
        case .unavailable: return "location.slash"
        case .idle: return "location"
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
        case .idle: return "Show my location"
        case .locating: return "Finding your location"
        case .located: return location.followsHeading ? "Face north" : "Face my direction of travel"
        case .denied: return "Location access is off. Enable it in Settings to use this."
        case .unavailable(let message): return message
        }
    }
}
