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
    private let trackHeight: CGFloat = 58
    private let handleSize = CGSize(width: 26, height: 20)

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            track
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
        .help(on ? "Vinyl — flip down for Original" : "Original — flip up for Vinyl")
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
                // Grip lines.
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(Theme.Palette.insetLo.opacity(0.8))
                            .frame(width: handleSize.width - 12, height: 1)
                            .overlay(
                                Capsule().fill(Theme.Palette.insetHi.opacity(0.25))
                                    .offset(y: 0.7)
                            )
                    }
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
            .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1.5)
            .shadow(color: .black.opacity(0.2), radius: 4, y: 3)
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
                .font(WindowChrome.microFont)
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
            .overlay(alignment: .topLeading) { ScrewHead().padding(11) }
            .overlay(alignment: .topTrailing) { ScrewHead(angle: 32).padding(11) }
            .overlay(alignment: .bottomLeading) { ScrewHead(angle: -18).padding(11) }
            .overlay(alignment: .bottomTrailing) { ScrewHead(angle: 74).padding(11) }
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

/// A tiny slotted screw. Each corner gets a different slot angle — machines are
/// assembled by hands, not mirrored.
@available(macOS 14.2, *)
struct ScrewHead: View {
    var angle: Double = 0
    var d: CGFloat = 10

    var body: some View {
        Circle()
            .fill(
                RadialGradient(colors: [Theme.Palette.ctrlLight, Theme.Palette.ctrlDark],
                               center: UnitPoint(x: 0.38, y: 0.32),
                               startRadius: 0, endRadius: d * 0.8)
            )
            .overlay(
                Capsule()
                    .fill(Theme.Palette.insetLo)
                    .frame(width: d - 2, height: 1)
                    .rotationEffect(.degrees(angle))
            )
            .overlay(Circle().strokeBorder(Theme.Palette.bezelDark.opacity(0.8), lineWidth: 0.5))
            .frame(width: d, height: d)
            .shadow(color: .black.opacity(0.35), radius: 0.8, y: 0.8)
            .allowsHitTesting(false)
    }
}
