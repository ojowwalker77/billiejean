import SwiftUI
import AppKit

// MARK: - The skeuomorphic material kit (Braun-inspired)
//
// Instrument surfaces — the faceplate and everything mounted on it — are NOT
// chrome. Chrome stays liquid glass per the skeleton; the deck is a physical
// object: layered inset shadows (light falls from the top-left), matte
// faceplate, engraved ink, and hardware colors used sparingly (one orange,
// one green — the Braun way).

// MARK: Inner shadow

@available(macOS 14.2, *)
extension View {
    /// Classic inner shadow: a blurred, offset stroke clipped to the shape.
    func innerShadow<S: InsettableShape>(
        _ shape: S, color: Color, lineWidth: CGFloat = 2,
        blur: CGFloat = 2, x: CGFloat = 0, y: CGFloat = 0
    ) -> some View {
        overlay(
            shape
                .stroke(color, lineWidth: lineWidth)
                .blur(radius: blur)
                .offset(x: x, y: y)
                .mask(shape.fill())
                .allowsHitTesting(false)
        )
    }

    /// A recessed well in the faceplate (VU window, lever track): darker fill,
    /// dark inner shadow from the top, a light lip at the bottom edge.
    func insetWell(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(
            shape.fill(Theme.Palette.faceWell)
                .innerShadow(shape, color: Theme.Palette.insetLo, lineWidth: 2.5, blur: 2.5, y: 2)
                .innerShadow(shape, color: Theme.Palette.insetLo.opacity(0.5), lineWidth: 1, blur: 1, x: 1)
                .overlay(
                    shape.strokeBorder(Theme.Palette.faceEdgeLight, lineWidth: 1)
                        .mask(
                            shape.fill(
                                LinearGradient(colors: [.clear, .black],
                                               startPoint: .center, endPoint: .bottom)
                            )
                        )
                )
        )
    }
}

// MARK: Raised control surface (the CSS recipe, translated)

/// The layered raised-control look: 135° face gradient, white inset highlight
/// from the top-left, dark inset shade at the bottom-right, a bezel ring, and a
/// two-layer drop shadow. `pressed` inverts it — dark inset floods from the
/// top-left, the highlight dies, the drop shadow collapses: the control sinks.
@available(macOS 14.2, *)
struct SkeuoRaisedCircle: ViewModifier {
    var diameter: CGFloat
    var pressed: Bool
    /// Draw a recessed mounting well behind the control (deck keys sit in
    /// machined recesses — this is what separates "3D" from "gray circle").
    var mounted = true

    func body(content: Content) -> some View {
        let face = LinearGradient(
            colors: pressed
                ? [Theme.Palette.ctrlDark, Theme.Palette.ctrlLight.opacity(0.9)]
                : [Theme.Palette.ctrlLight, Theme.Palette.ctrlDark],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )

        return content
            .frame(width: diameter, height: diameter)
            .background(
                ZStack {
                    if mounted {
                        // The recess the key sits in: darker well, shadow from
                        // above, a faint lip light at its bottom edge.
                        Circle()
                            .fill(Theme.Palette.faceWell)
                            .frame(width: diameter + 10, height: diameter + 10)
                            .innerShadow(Circle(), color: Theme.Palette.insetLo,
                                         lineWidth: 2.5, blur: 2.5, y: 2)
                            .overlay(
                                Circle().strokeBorder(Theme.Palette.faceEdgeLight, lineWidth: 1)
                                    .mask(
                                        Circle().fill(
                                            LinearGradient(colors: [.clear, .black],
                                                           startPoint: .center, endPoint: .bottom)
                                        )
                                    )
                                    .frame(width: diameter + 10, height: diameter + 10)
                            )
                    }
                    Circle().fill(face)
                    if pressed {
                        // Sunk: dark floods from above, faint light pools below.
                        Circle().fill(Color.clear)
                            .innerShadow(Circle(), color: Theme.Palette.insetLo,
                                         lineWidth: 3, blur: 3, x: 1, y: 2.5)
                            .innerShadow(Circle(), color: Theme.Palette.insetHi.opacity(0.35),
                                         lineWidth: 1, blur: 1, y: -1)
                    } else {
                        // Raised: light catches the top-left lip, shade hugs the bottom.
                        Circle().fill(Color.clear)
                            .innerShadow(Circle(), color: Theme.Palette.insetHi,
                                         lineWidth: 1.5, blur: 1.2, x: -0.5, y: -1)
                            .innerShadow(Circle(), color: Theme.Palette.insetLo.opacity(0.8),
                                         lineWidth: 2, blur: 2.5, x: 1, y: 2)
                    }
                    Circle().strokeBorder(Theme.Palette.bezelDark, lineWidth: 1)
                }
                // Rasterize: the inset-shadow stack is several live blur layers;
                // cached as one texture per press-state it costs nothing.
                .drawingGroup()
            )
            .offset(y: pressed ? 1 : 0)
            .shadow(color: .black.opacity(pressed ? 0.20 : 0.45),
                    radius: pressed ? 0.5 : 1, y: pressed ? 0.5 : 1)
            .shadow(color: .black.opacity(pressed ? 0.08 : 0.22),
                    radius: pressed ? 2 : 6, y: pressed ? 1 : 3.5)
    }
}

// MARK: Slide lever (the A/B switch — like a 45/33 speed selector)

/// A vertical two-position lever in a recessed track. Up = VINYL (processed),
/// down = ORIGINAL. Engraved position labels beside the track; the handle is a
/// dark gripped block that snaps between detents with a spring and a haptic.
@available(macOS 14.2, *)
struct SlideLever: View {
    /// true = up position (VINYL).
    let on: Bool
    var action: () -> Void

    private let trackWidth: CGFloat = 14
    private let trackHeight: CGFloat = 92
    private let handleSize = CGSize(width: 36, height: 28)

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            track
                .padding(.vertical, 14)
                .padding(.horizontal, 9)
                // Escutcheon: the raised mounting plate the lever lives on,
                // with a machined edge and its own two screws.
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(colors: [Theme.Palette.faceTop, Theme.Palette.faceBottom],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .overlay(
                            // Machined edge: bright top lip, dark undercut.
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.Palette.insetHi.opacity(0.30), lineWidth: 0.8)
                                .mask(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
                                        LinearGradient(colors: [.black, .clear],
                                                       startPoint: .top, endPoint: .center)
                                    )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.Palette.bezelDark.opacity(0.8), lineWidth: 0.8)
                        )
                        .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2.5)
                )
                .overlay(alignment: .top) { ScrewHead(angle: 21, d: 9).offset(y: 2.5) }
                .overlay(alignment: .bottom) { ScrewHead(angle: 67, d: 9).offset(y: -2.5) }
            labels
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.level()
            action()
        }
        .gesture(
            DragGesture(minimumDistance: 6)
                .onEnded { g in
                    let wantsOn = g.translation.height < 0
                    if wantsOn != on {
                        Haptics.level()
                        action()
                    }
                }
        )
        // No .help: the engraved VINYL/ORIG labels are the affordance.
    }

    private var track: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color.clear)
                .frame(width: trackWidth, height: trackHeight)
                .insetWell(radius: trackWidth / 2)

            handle
                .offset(y: on ? -(trackHeight - handleSize.height) / 2 + 2
                              : (trackHeight - handleSize.height) / 2 - 2)
                .animation(ChromeMotion.spring, value: on)
        }
        .frame(width: handleSize.width, height: trackHeight)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(
                LinearGradient(colors: [Theme.Palette.leverTop, Theme.Palette.leverBottom],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                // Grip ridges around a center index line.
                VStack(spacing: 2.5) {
                    gripLine
                    Capsule().fill(Theme.Palette.body)
                        .frame(width: handleSize.width - 10, height: 1.4)
                    gripLine
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Theme.Palette.bezelDark, lineWidth: 0.75)
            )
            .innerShadow(RoundedRectangle(cornerRadius: 5, style: .continuous),
                         color: Theme.Palette.insetHi.opacity(0.5),
                         lineWidth: 1, blur: 0.8, y: -0.8)
            .frame(width: handleSize.width, height: handleSize.height)
            .drawingGroup()
            .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1.5)
            .shadow(color: .black.opacity(0.2), radius: 4, y: 3)
    }

    private var gripLine: some View {
        Capsule()
            .fill(Theme.Palette.insetLo.opacity(0.8))
            .frame(width: handleSize.width - 14, height: 0.8)
            .overlay(
                Capsule().fill(Theme.Palette.insetHi.opacity(0.25)).offset(y: 0.6)
            )
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 0) {
            positionLabel("VINYL", active: on)
            Spacer(minLength: 0)
            positionLabel("ORIG", active: !on)
        }
        .frame(height: trackHeight - 6)
    }

    private func positionLabel(_ text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? Theme.Palette.hwOrange : Theme.Palette.printedInk.opacity(0.25))
                .frame(width: 3.5, height: 3.5)
                .shadow(color: active ? Theme.Palette.hwOrange.opacity(0.7) : .clear, radius: 2.5)
            Text(text)
                .font(WindowChrome.captionFont)
                .foregroundStyle(active ? Theme.Palette.body : Theme.Palette.printedInk)
        }
        .animation(ChromeMotion.hover, value: active)
    }
}

// MARK: Faceplate

/// The deck's face: a matte plate with a soft vertical falloff, a lit top edge,
/// and four corner screws. This is deliberately NOT the glass recipe — the
/// panel is the instrument, not chrome.
@available(macOS 14.2, *)
struct Faceplate: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(
                shape.fill(
                    LinearGradient(colors: [Theme.Palette.faceTop, Theme.Palette.faceBottom],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    shape.strokeBorder(Theme.Palette.faceEdgeLight, lineWidth: 1)
                        .mask(
                            shape.fill(
                                LinearGradient(colors: [.black, .clear],
                                               startPoint: .top, endPoint: .center)
                            )
                        )
                )
                .overlay(shape.strokeBorder(Theme.Palette.bezelDark.opacity(0.6), lineWidth: 1))
            )
            .overlay(alignment: .topLeading) { ScrewHead().padding(14) }
            .overlay(alignment: .topTrailing) { ScrewHead(angle: 32).padding(14) }
            .overlay(alignment: .bottomLeading) { ScrewHead(angle: -18).padding(14) }
            .overlay(alignment: .bottomTrailing) { ScrewHead(angle: 74).padding(14) }
            .shadow(color: Theme.Shadow.panel.color,
                    radius: Theme.Shadow.panel.radius, y: Theme.Shadow.panel.y)
    }
}

@available(macOS 14.2, *)
extension View {
    func faceplate(radius: CGFloat) -> some View {
        modifier(Faceplate(radius: radius))
    }
}

/// A countersunk phillips screw. Each corner gets a different cross angle —
/// machines are assembled by hands, not mirrored.
@available(macOS 14.2, *)
struct ScrewHead: View {
    var angle: Double = 0
    var d: CGFloat = 18

    var body: some View {
        ZStack {
            // Countersink: the recess the head sits in.
            Circle()
                .fill(Theme.Palette.faceWell)
                .frame(width: d + 6, height: d + 6)
                .innerShadow(Circle(), color: Theme.Palette.insetLo,
                             lineWidth: 2, blur: 1.6, y: 1.2)
                .overlay(
                    Circle().strokeBorder(Theme.Palette.faceEdgeLight, lineWidth: 0.7)
                        .mask(
                            Circle().fill(
                                LinearGradient(colors: [.clear, .black],
                                               startPoint: .center, endPoint: .bottom)
                            )
                        )
                        .frame(width: d + 6, height: d + 6)
                )

            // Head: domed metal with a turned rim bevel.
            Circle()
                .fill(
                    RadialGradient(colors: [Theme.Palette.ctrlLight, Theme.Palette.ctrlDark],
                                   center: UnitPoint(x: 0.36, y: 0.30),
                                   startRadius: 0, endRadius: d * 0.85)
                )
                .overlay(
                    // The machined bevel ring just inside the edge.
                    Circle().inset(by: d * 0.12)
                        .strokeBorder(Theme.Palette.insetHi.opacity(0.35), lineWidth: 0.7)
                )
                .overlay(
                    Circle().inset(by: d * 0.12 + 0.7)
                        .strokeBorder(Theme.Palette.insetLo.opacity(0.45), lineWidth: 0.6)
                )
                .overlay(Circle().strokeBorder(Theme.Palette.bezelDark.opacity(0.8), lineWidth: 0.7))
                .innerShadow(Circle(), color: Theme.Palette.insetHi.opacity(0.6),
                             lineWidth: 1, blur: 0.7, y: -0.6)
                .frame(width: d, height: d)
                .shadow(color: .black.opacity(0.45), radius: 1, y: 1)

            // Phillips cross: each slot is a dark cut with a light lower lip
            // (the stamped-metal read), tapered toward the center dimple.
            ZStack {
                crossSlot
                crossSlot.rotationEffect(.degrees(90))
                Circle()
                    .fill(Theme.Palette.insetLo)
                    .frame(width: d * 0.16, height: d * 0.16)
            }
            .rotationEffect(.degrees(angle))
        }
        .frame(width: d + 6, height: d + 6)
        .drawingGroup()
        .allowsHitTesting(false)
    }

    private var crossSlot: some View {
        ZStack {
            Capsule()
                .fill(Theme.Palette.insetLo)
                .frame(width: d - 4.5, height: d * 0.13)
            Capsule()
                .fill(Theme.Palette.insetHi.opacity(0.45))
                .frame(width: d - 6, height: d * 0.06)
                .offset(y: d * 0.09)
        }
    }
}

// MARK: Vertical deck fader (the Technics pitch-fader grammar)

/// A vertical slider in a recessed channel: printed tick scale beside the slot,
/// an orange detent dot at the control's default position, and a gripped dark
/// cap with a center index line. Drag the cap, scroll over it, double-click to
/// reset. Value 1 = top.
@available(macOS 14.2, *)
struct DeckFader: View {
    let help: String
    @Binding var value: Double
    let onReset: () -> Void

    var height: CGFloat = 96
    var label: String? = nil
    /// Default position, marked beside the channel with the hardware orange.
    var detent: Double? = nil

    private static let detentStep = 0.05

    private let slotWidth: CGFloat = 8
    private let capSize = CGSize(width: 24, height: 15)
    private var travel: CGFloat { height - capSize.height }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                channel
                scale
                if let detent {
                    Circle()
                        .fill(Theme.Palette.hwOrange)
                        .frame(width: 3, height: 3)
                        .shadow(color: Theme.Palette.hwOrange.opacity(0.6), radius: 2)
                        .offset(x: 12, y: yOffset(for: detent))
                }
                cap
            }
            .frame(width: 44, height: height)
            .contentShape(Rectangle())
            .overlay(
                FaderCatcher(
                    onScroll: { delta, precise in
                        let pointsPerFullRange = precise ? Double(travel) * 1.6 : 30
                        apply((value + delta / pointsPerFullRange).clamped01)
                    },
                    onDragDelta: { dy in
                        apply((value - dy / Double(travel)).clamped01)
                    },
                    onDoubleClick: {
                        onReset()
                        Haptics.level()
                    }
                )
            )
            // No .help here: every tooltip registers a hover tracker, and each
            // pointer move hit-tests the whole tree (measured jank). The
            // printed label under the fader is the affordance.
            if let label {
                Text(label)
                    .font(WindowChrome.captionFont)
                    .foregroundStyle(Theme.Palette.printedInk)
                    .lineLimit(1)
            }
        }
    }

    private func yOffset(for v: Double) -> CGFloat {
        travel * CGFloat(0.5 - v.clamped01)
    }

    private func apply(_ new: Double) {
        let old = value
        guard new != old else { return }
        value = new
        let performer = NSHapticFeedbackManager.defaultPerformer
        if (new == 0 && old > 0) || (new == 1 && old < 1) {
            performer.perform(.levelChange, performanceTime: .default)
        } else if Int(old / Self.detentStep) != Int(new / Self.detentStep) {
            performer.perform(.alignment, performanceTime: .default)
        }
    }

    // The recessed slot with a darker center guide line.
    private var channel: some View {
        ZStack {
            Color.clear
                .frame(width: slotWidth, height: height)
                .insetWell(radius: slotWidth / 2)
            Rectangle()
                .fill(Theme.Palette.insetLo.opacity(0.8))
                .frame(width: 1.5, height: height - 6)
        }
        .drawingGroup()
    }

    // Printed ticks left of the slot; ends and center slightly stronger.
    private var scale: some View {
        ZStack {
            ForEach(0..<9, id: \.self) { i in
                let t = Double(i) / 8.0
                let strong = i == 0 || i == 4 || i == 8
                Rectangle()
                    .fill(Theme.Palette.printedInk.opacity(strong ? 0.65 : 0.35))
                    .frame(width: strong ? 6 : 4, height: 0.75)
                    .offset(x: -12, y: -travel / 2 + travel * t)
            }
        }
        .allowsHitTesting(false)
    }

    // The fader cap: gripped dark block with a center index line.
    private var cap: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(colors: [Theme.Palette.leverTop, Theme.Palette.leverBottom],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Theme.Palette.bezelDark, lineWidth: 0.75)
                )
                .innerShadow(RoundedRectangle(cornerRadius: 3, style: .continuous),
                             color: Theme.Palette.insetHi.opacity(0.5),
                             lineWidth: 1, blur: 0.8, y: -0.8)
            // Grip ridges above and below the index line.
            VStack(spacing: 2.5) {
                gripLine
                // Center index line — the white stripe you read the value by.
                Capsule().fill(Theme.Palette.body)
                    .frame(width: capSize.width - 6, height: 1.4)
                gripLine
            }
        }
        .frame(width: capSize.width, height: capSize.height)
        .drawingGroup()
        .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1.5)
        .shadow(color: .black.opacity(0.2), radius: 4, y: 3)
        .offset(y: yOffset(for: value))
        .animation(.easeOut(duration: 0.06), value: value)
    }

    private var gripLine: some View {
        Capsule()
            .fill(Theme.Palette.insetLo.opacity(0.7))
            .frame(width: capSize.width - 10, height: 0.8)
            .overlay(
                Capsule().fill(Theme.Palette.insetHi.opacity(0.25)).offset(y: 0.6)
            )
    }
}

/// Scroll + vertical-drag + double-click catcher for the fader. Drag reports
/// per-event deltas (positive dy = pointer moved down).
@available(macOS 14.2, *)
private struct FaderCatcher: NSViewRepresentable {
    let onScroll: (Double, Bool) -> Void
    let onDragDelta: (Double) -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.onDragDelta = onDragDelta
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onDragDelta = onDragDelta
        nsView.onDoubleClick = onDoubleClick
    }

    final class CatcherView: NSView {
        var onScroll: ((Double, Bool) -> Void)?
        var onDragDelta: ((Double) -> Void)?
        var onDoubleClick: (() -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }

        override func scrollWheel(with event: NSEvent) {
            var delta = Double(event.scrollingDeltaY)
            if event.isDirectionInvertedFromDevice { delta = -delta }
            guard delta != 0 else { return }
            onScroll?(delta, event.hasPreciseScrollingDeltas)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick?() }
        }

        override func mouseDragged(with event: NSEvent) {
            onDragDelta?(Double(event.deltaY))
        }
    }
}
