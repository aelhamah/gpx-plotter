import SwiftUI
import RouteKit

/// Base layer and overlay choice, as its own sheet.
///
/// ## Why these moved off the map
///
/// They were four loose circles on the map competing with three others for the
/// same column, and two of the four were toggles whose state was invisible — so
/// the map carried two extra buttons to say nothing, and reading "is slope
/// shading on?" was a matter of memory.
///
/// Apple keeps exactly two things on the map (map type, your location) and puts
/// the rest behind one control that opens this. The arrangement inside is theirs
/// too: a row of mode tiles with the current one outlined, then the overlay
/// toggles below.
///
/// Both screens bind to the same `WorkspaceStore` flags, so the sheet and the
/// terrain toggle on the map cannot disagree about what is switched on.
struct MapModesSheet: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    modeTiles
                    if AppConfig.canShowTerrainOverlays || AppConfig.canUseTerrain3D {
                        overlayToggles
                    }
                    limitation
                }
                .padding(20)
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The base layer, as selectable tiles.
    ///
    /// A tile rather than a segmented control because there are only two options
    /// and a reader wants to see what each one *looks* like, not read its name.
    private var modeTiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Base Layer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(MapStyle.allCases) { style in
                    ModeTile(
                        style: style,
                        isSelected: workspace.mapStyle == style
                    ) {
                        workspace.mapStyle = style
                    }
                }
            }
        }
    }

    /// One basemap, drawn as a swatch rather than as a screenshot.
    ///
    /// A real thumbnail would mean rendering the style offscreen and keeping it in
    /// step with the proxy, which is a lot of machinery to decorate two
    /// rectangles. The swatch is a plan-view motif per style instead: imagery for
    /// satellite, contours and land for outdoor. It is honest about the *kind* of
    /// map, which is the decision being made.
    private var overlayToggles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Overlays")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                if AppConfig.canUseTerrain3D {
                    toggleRow("cube.transparent", "3D terrain", isOn: $workspace.showTerrain3D)
                    Divider()
                }
                if AppConfig.canShowTerrainOverlays {
                    toggleRow("square.3.layers.3d.top.filled", "Relief shading", isOn: $workspace.showHillshade)
                    if AppConfig.canUseTerrain3D { Divider() }
                }
                if AppConfig.canShowTerrainOverlays {
                    toggleRow("mountain.2.fill", "Slope shading", isOn: $workspace.showSlope)
                }
            }
        }
    }

    /// Says why a control is missing rather than leaving a hole in the sheet.
    ///
    /// A gap with no explanation reads as a bug; the demo basemap genuinely cannot
    /// do any of this, and that is worth saying out loud.
    @ViewBuilder
    private var limitation: some View {
        if let note = AppConfig.baseLayerLimitation ?? AppConfig.terrainLimitation {
            Label {
                Text(note).font(.caption)
            } icon: {
                Image(systemName: "info.circle")
            }
            .foregroundStyle(.secondary)
        }
    }

    private func toggleRow(_ symbol: String, _ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label {
                Text(label)
            } icon: {
                Image(systemName: symbol)
                    .frame(width: 24)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One selectable basemap.
private struct ModeTile: View {
    let style: MapStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Swatch(style: style)
                    .frame(height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                lineWidth: isSelected ? 3 : 1
                            )
                    }
                Text(style.title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A plan-view stand-in for a basemap.
private struct Swatch: View {
    let style: MapStyle

    var body: some View {
        Canvas { context, size in
            let land = style == .satellite ? Color(red: 0.16, green: 0.22, blue: 0.14)
                                           : Color(red: 0.86, green: 0.89, blue: 0.80)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(land))

            // A road, and a contour-ish curve for the outdoor map, so the two
            // swatches are distinguishable at 72pt.
            var road = Path()
            road.move(to: CGPoint(x: 0, y: size.height * 0.7))
            road.addLine(to: CGPoint(x: size.width, y: size.height * 0.35))
            context.stroke(
                road,
                with: .color(style == .satellite ? Color.white.opacity(0.85) : Color.white),
                lineWidth: style == .satellite ? 5 : 4
            )

            if style == .outdoor {
                for index in 1...3 {
                    var contour = Path()
                    let y = size.height * (0.2 + Double(index) * 0.22)
                    contour.move(to: CGPoint(x: 0, y: y))
                    contour.addCurve(
                        to: CGPoint(x: size.width, y: y - 14),
                        control1: CGPoint(x: size.width * 0.35, y: y - 20),
                        control2: CGPoint(x: size.width * 0.65, y: y + 12)
                    )
                    context.stroke(contour, with: .color(Color.brown.opacity(0.5)), lineWidth: 1.5)
                }
            }
        }
    }
}