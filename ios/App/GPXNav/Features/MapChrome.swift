import SwiftUI
import RouteKit

/// Screen furniture the map has to keep clear of, so nothing it draws lands
/// under chrome the reader cannot see past.
///
/// ## The two rails
///
/// Apple's Maps puts its map controls in **two columns, both anchored to the
/// sheet's top edge** — a rail of separate circles on the left, one capsule on
/// the right — and nothing else. This file used to put four circles at the top of
/// the map and two at the bottom, in two different corners, each positioned by its
/// own padding.
///
/// That is not a style difference, it is a bug waiting to happen, and the bug
/// happened: the bottom pair was inset by the sheet's height while the top group
/// was pinned to the navigation bar, so raising the sheet drove the bottom pair
/// up through the top one. On the device this was measured on there were 143pt
/// between them and expanding the sheet moves it 324pt — an overlap of 98pt, with
/// both buttons landing inside the other cluster.
///
/// One bottom-anchored band with a compile-time-constant height cannot do that.
/// There is no second cluster to converge with, so the arithmetic cannot go wrong
/// on a device whose insets differ from the one it was measured on.
enum MapChrome {
    /// A map button's diameter. Apple's is 48; ours was 44.
    static let controlSize: CGFloat = 48

    /// Gap between one control and the next, within a rail.
    static let controlSpacing: CGFloat = 10

    /// Gap between the sheet's top edge and the rails sitting above it.
    static let railInset: CGFloat = 12

    /// The left rail's height: one circle.
    ///
    /// It was two — compass and fit — and the detent arithmetic above is why it
    /// never became three: at the expanded detent the rail shares its band with
    /// the top-leading chrome (the waypoint chip, and until recently the search
    /// button). The compass is gone now (it duplicated what `LocateButton`
    /// already does once the location is known; see `MapControlRail`), so the
    /// rail is a single framing control with all of the clearance the
    /// two-circle version had and more to spare.
    static let railHeight = controlSize

    /// The hairline between the two halves of the right capsule.
    static let pillDivider: CGFloat = 1

    /// Height of the right capsule: two targets and the divider between them.
    static let pillHeight = controlSize * 2 + pillDivider

    /// Room for the bottom sheet at its shortest detent, plus a margin.
    ///
    /// Drives where the map's own buttons sit so they clear the sheet, which is
    /// why it follows the panel's height rather than being its own number.
    @MainActor
    static func bottomInset(panelHeight: CGFloat) -> CGFloat {
        panelHeight + railInset
    }
}

/// Frames of the chrome drawn over the map, in screen coordinates, reported by
/// the chrome itself.
///
/// The label layout needs to know where the controls are, and deriving that
/// from detents, paddings, and safe-area constants meant every layer of the
/// stack had to agree about them — when they did not, the obstacle rects
/// landed in empty space, which is invisible until a label sits under a
/// button. A frame measured by the view that draws the control cannot drift
/// from where that control actually is.
struct ChromeFramesPreference: PreferenceKey {
    // `let`, not `var`: the protocol asks only for a getter, and a mutable
    // static would be shared global state under the strict concurrency rules.
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reports this view's frame under `name`, in screen coordinates, through
    /// `ChromeFramesPreference`.
    ///
    /// Screen coordinates are the same space the map's own projection
    /// (`MLNMapView.convert`) and the label overlay (which ignores the safe
    /// area) both use, so the frames need no translation on the way in.
    func chromeFrame(_ name: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ChromeFramesPreference.self,
                    value: [name: geometry.frame(in: .global)]
                )
            }
        }
    }
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
            // Breathing room below the sheet's top edge, which also keeps the glyph clear of
            // the corner arc. (It was originally added to survive a hardcoded
            // 20pt `presentationCornerRadius`; the radius is the system's now, so
            // this is just space.)
            .padding(.top, 6)
            .frame(height: PanelMetrics.expandChevronHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .accessibilityLabel(isExpanded ? "Collapse the panel" : "Expand the panel")
    }
}

/// Waypoint names, drawn over the map in the map view's own coordinates.
///
/// Laid out in SwiftUI rather than as a MapLibre symbol layer — see the note on
/// `MapView.waypointLabels` for why.
///
/// Positions arrive fully resolved from `MapView.refreshWaypointLabels`: each
/// point is the centre of a capsule already clamped to the available area and
/// checked against the chrome and the other labels. This view does no placement
/// of its own, which is what keeps the drawn capsule and the rect that was
/// collision-checked the same size — a renderer that re-measured or re-clamped
/// would be re-solving a problem the layout already solved, with different
/// inputs.
struct WaypointLabelOverlay: View {
    let labels: [ProjectedWaypoint]

    var body: some View {
        // The overlay spans the map view, which ignores the safe area, so these are
        // map-view points rather than screen points — and the overlay has to
        // ignore the safe area too, or its origin sits below the status bar and
        // every label lands ~110 pt under its waypoint.
        // GeometryReader rather than a bare ZStack: `.position` resolves against
        // the space it is given, and only GeometryReader is guaranteed to take
        // all of the space the overlay proposes.
        GeometryReader { _ in
            ForEach(labels) { label in
                Text(label.text)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .fixedSize()
                    .position(x: label.point.x, y: label.point.y)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The map's framing control, as a single circle.
///
/// It used to hold the compass above the fit button, but the compass was a
/// duplicate: `LocateButton` in `MapControlPill` already runs
/// `location.cycleLocateMode()` — the same question of orientation and
/// location, behind a different glyph. Orientation and location are one
/// question, which is the capsule's whole reason to exist; the compass joined
/// it by disappearing into the control that already answered it.
struct MapControlRail: View {
    let onFit: () -> Void

    var body: some View {
        FitButton(action: onFit)
            .chromeFrame("rail")
    }
}

/// The map-type and locate controls, as one capsule.
///
/// ## Why these two share a container
///
/// This is the difference from the loose-column layout it replaces, and it is
/// Apple's own: **a circle means one action, a capsule means a small family of
/// them.** Map type and "where am I" are the same question asked about the same
/// map, and on Apple Maps they are a single object with a hairline between them —
/// which also means they cannot be drawn out of step with each other, because
/// there is nothing to keep in step.
///
/// The hairline is the affordance: it says "these are separate controls" without
/// spending a second border on a 48pt target.
struct MapControlPill: View {
    var onShowMapModes: () -> Void

    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onShowMapModes) {
                Image(systemName: "globe.americas.fill")
            }
            .accessibilityLabel("Map type and overlays")

            Rectangle()
                .fill(.primary.opacity(0.12))
                .frame(width: MapChrome.controlSize - 24, height: MapChrome.pillDivider)

            LocateButton()
        }
        .buttonStyle(ChromeButtonStyle())
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MapChrome.controlSize / 2))
        .shadow(radius: 2, y: 1)
        .frame(width: MapChrome.controlSize, height: MapChrome.pillHeight)
        .chromeFrame("pill")
    }
}

/// A toggle that shows whether it is on.
///
/// The old style only reacted to being pressed, so relief shading, slope shading
/// and 3D terrain all looked exactly the same whichever way they were set — there
/// was no way to tell from the map that slope shading was on at all. Apple's
/// controls for the same thing ("3D", the map-type globe) fill in when selected,
/// and that is the whole vocabulary of a toggle.
struct ToggleChromeButton: View {
    let symbol: String
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: symbol)
        }
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .help(label)
        .buttonStyle(ChromeButtonStyle(isOn: isOn))
    }
}

/// Re-frames the camera on the route, for when panning has lost it.
struct FitButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FitGlyph()
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 17, height: 17)
        }
        .buttonStyle(ChromeButtonStyle())
        .accessibilityLabel("Fit the route to the screen")
    }
}

/// The web app's fit glyph: four corner brackets, ported from the inline SVG on
/// `#fit-route` (`M8 3H5a2 2 0 0 0-2 2v3…`, a 24×24 viewBox, stroke-width 2).
///
/// Not an SF Symbol: `scope` — the crosshair this used to draw — is a reticle
/// with a centre mark, where the web control is corner brackets, and the two do
/// not read as the same button. The bracket is drawn once and rotated four
/// times about the centre, so the four corners cannot drift out of step.
struct FitGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 24
        // Centre-relative, so each rotation below is about the glyph's own
        // centre and needs no translation of its own.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (x - 12) * scale, y: (y - 12) * scale)
        }

        // The top-left bracket of the web path: a horizontal arm, a round
        // corner, a vertical arm. The corner is a true quarter arc of the
        // 24-unit circle centred at (5,5), as the SVG's `a2 2 0 0 0-2 2` draws
        // it, approximated by the standard circular cubic (k = 0.5523) — under
        // 0.03% chord error, which is a rounding error at this size.
        let k: CGFloat = 1.1046
        var bracket = Path()
        bracket.move(to: point(8, 3))
        bracket.addLine(to: point(5, 3))
        bracket.addCurve(to: point(3, 5), control1: point(5 - k, 3), control2: point(3, 5 - k))
        bracket.addLine(to: point(3, 8))

        var rotated = Path()
        for quarter in 0..<4 {
            rotated.addPath(
                bracket,
                transform: CGAffineTransform(rotationAngle: CGFloat(quarter) * .pi / 2)
            )
        }
        var path = Path()
        path.addPath(
            rotated,
            transform: CGAffineTransform(translationX: rect.midX, y: rect.midY)
        )
        return path
    }
}

/// The six avalanche slope bands, matching `SlopeBands.slopeBandColorHex` and the
/// web app's `#slope-legend`.
///
/// On the map at the web app's own corner — bottom-right, above the controls —
/// shown with the shading it explains, rather than under the profile chart,
/// which is where this used to sit: the web legend is an on-map overlay
/// toggled with the slope layer (`main.ts` toggles `#slope-legend` with
/// `slopeEnabled`), and the chart it appeared to explain is coloured the same
/// way with or without it.
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Slope angle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "#0f172a"))
            ForEach(Self.bands, id: \.label) { band in
                HStack(spacing: 7) {
                    Capsule()
                        .fill(Color(hex: band.hex))
                        .frame(width: 15, height: 6)
                    Text(band.label)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "#0f172a"))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Slope \(band.label)")
            }
        }
        // The web card: `rgba(255,255,255,.85)` over the map, a `rgba(0,0,0,.12)`
        // hairline, 9pt corners, a soft shadow. A fixed white rather than the
        // system material, because the legend's dark ink is part of the look —
        // it is the same card the web app draws at `right: 18px; bottom: 28px`.
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }
}

/// Circular map button, matching `LocateButton`'s own framing so the rail and
/// the capsule read as one control system.
///
/// `isOn` is what turns a row of identical grey discs into something you can
/// read at a glance: a filled disc means the overlay is on. Without it, relief,
/// slope and 3D terrain were three identical circles whose only difference was
/// something you had to remember doing.
struct ChromeButtonStyle: ButtonStyle {
    var isOn = false
    /// Overrides the glyph colour, for the one control whose colour means
    /// something: locate goes dim when location access is off, which is the only
    /// warning it gives before you tap it and learn why nothing happened.
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(glyphStyle)
            .frame(width: MapChrome.controlSize, height: MapChrome.controlSize)
            .background(.regularMaterial, in: Circle())
            .shadow(radius: 2, y: 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }

    private var glyphStyle: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint) }
        return isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)
    }
}