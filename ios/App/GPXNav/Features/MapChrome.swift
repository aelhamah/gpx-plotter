import SwiftUI
import RouteKit

/// Screen furniture the map has to keep clear of, so nothing it draws lands
/// under chrome the reader cannot see past.
enum MapChrome {
    /// The translucent navigation bar the map runs under.
    static let topInset: CGFloat = 52
    /// Room for the bottom sheet at its shortest detent, plus the home indicator.
    static var bottomInset: CGFloat { AppConfig.statsOnlyPanelHeight + 12 }
    /// How far in from a screen edge a waypoint label is allowed to sit.
    static let labelEdgeMargin: CGFloat = 68
    /// Height of the sheet's expand/collapse affordance row.
    static let expandChevronHeight: CGFloat = 28
}

/// Says which way the sheet drags, standing in for the system drag indicator.
///
/// The grabber it replaces is a neutral pill that says nothing about the result,
/// which left the collapsed sheet looking like an unfinished row: four figures and
/// then a band of empty material. This fills that band with the actual affordance
/// and flips with the detent, so the collapsed state reads as "there is more" and
/// the expanded one as "there is less".
struct PanelExpandChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.tertiary)
            // Top padding, because the sheet's 20pt corner radius clips whatever
            // sits flush against the edge and the glyph was being sliced in half.
            .padding(.top, 6)
            .frame(height: MapChrome.expandChevronHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .accessibilityLabel(isExpanded ? "Collapse the panel" : "Expand the panel")
    }
}

/// Waypoint names, drawn over the map in the map view's own coordinates.
///
/// Laid out in SwiftUI rather than as a MapLibre symbol layer — see the note on
/// `MapView.waypointLabels` for why.
struct WaypointLabelOverlay: View {
    let labels: [ProjectedWaypoint]

    var body: some View {
        // The overlay spans the map view, which ignores the safe area, so these are
        // map-view points rather than screen points — and the overlay has to
        // ignore the safe area too, or its origin sits below the status bar and
        // every label lands ~110 pt under its waypoint.
        GeometryReader { geometry in
            ForEach(labels) { label in
                Text(label.text)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .fixedSize()
                    .position(
                        // Nudged in from the edge so a waypoint near the frame does
                        // not get a half-clipped name. The margin is a guess at half
                        // a label's width; without it the label simply runs off.
                        x: min(max(label.point.x, MapChrome.labelEdgeMargin),
                               max(MapChrome.labelEdgeMargin, geometry.size.width - MapChrome.labelEdgeMargin)),
                        y: label.point.y - MapLayers.Paint.waypointLabelOffset
                    )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The map's basemap and terrain toggles.
///
/// These used to live only in Settings, which made the slope and relief overlays
/// undiscoverable from the map itself — the two places you would think to reach
/// for them. Both screens bind to the same `WorkspaceStore` flags, so they cannot
/// disagree.
///
/// A control the basemap cannot support is omitted rather than shown greyed: a
/// permanently dead button on the map is worse than no button, and Settings still
/// carries the explanation of *why* it is missing.
struct MapLayerControls: View {
    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        VStack(spacing: 8) {
            if AppConfig.canSwitchBaseLayer {
                Button {
                    workspace.mapStyle = workspace.mapStyle == .outdoor ? .satellite : .outdoor
                } label: {
                    // The icon shows what a tap will give you, not what is already
                    // on screen, which is the usual convention for a toggle and
                    // the only one that works when the icons are this similar.
                    Image(systemName: workspace.mapStyle == .outdoor
                          ? "globe.americas.fill"
                          : "square.3.layers.3d")
                }
                .accessibilityLabel(workspace.mapStyle == .outdoor
                                    ? "Show satellite imagery"
                                    : "Show the outdoor map")
            }

            if AppConfig.canShowTerrainOverlays {
                toggle("square.3.layers.3d.top.filled", "Relief shading", isOn: $workspace.showHillshade)
                toggle("mountain.2.fill", "Slope shading", isOn: $workspace.showSlope)
            }
            if AppConfig.canUseTerrain3D {
                toggle("cube.transparent", "3D terrain", isOn: $workspace.showTerrain3D)
            }
        }
        .buttonStyle(MapChromeButtonStyle())
    }

    private func toggle(_ symbol: String, _ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol)
        }
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Re-frames the camera on the route, for when panning has lost it.
struct FitButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "scope")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .shadow(radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fit the route to the screen")
    }
}

/// The six avalanche slope bands, matching `SlopeBands.slopeBandColorHex` and the
/// web app's legend.
///
/// The ranges are stated here rather than derived from the band edges so the
/// labels read the way the web app's do (`20–30°`, not `20.0–29.9°`).
struct SlopeLegend: View {
    private static let bands: [(label: String, hex: String)] = [
        ("<20°", SlopeBands.slopeBandColorHex(10)),
        ("20–30°", SlopeBands.slopeBandColorHex(25)),
        ("30–35°", SlopeBands.slopeBandColorHex(32)),
        ("35–40°", SlopeBands.slopeBandColorHex(37)),
        ("40–45°", SlopeBands.slopeBandColorHex(42)),
        ("45°+", SlopeBands.slopeBandColorHex(50)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Slope angle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(Self.bands, id: \.label) { band in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color(hex: band.hex))
                            .frame(width: 8, height: 8)
                        Text(band.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Slope \(band.label)")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Circular map button, matching `LocateButton`'s own framing so the two stacks
/// read as one control column.
struct MapChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
            .shadow(radius: 2, y: 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}