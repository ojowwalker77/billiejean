import SwiftUI
import AppKit

/// A physical knob with a stem+bead above it. Scroll (wheel or trackpad) over
/// the knob column changes the value with haptic detents; double-click resets
/// to the default. Clicks on the knob never drag the window.
@available(macOS 14.2, *)
struct KnobView: View {
    enum Style { case chrome, black }

    let title: String
    let style: Style
    let skin: Skin
    @Binding var value: Double
    let onReset: () -> Void

    /// Diameter of the knob body.
    var diameter: CGFloat { style == .black ? 68 : 36 }

    /// Angle range: −135° … +135°.
    private let minAngle: Double = -135
    private let maxAngle: Double = 135

    private var indicatorAngle: Double {
        minAngle + (maxAngle - minAngle) * value.clamped01
    }

    var body: some View {
        VStack(spacing: 12) {
            stemAndBead
            knob
            Text(title)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(skin.secondary)
        }
        .contentShape(Rectangle())
        .modifier(KnobScrollInteraction(value: $value, onReset: onReset))
    }

    // MARK: - Stem + bead

    private var stemAndBead: some View {
        let stemHeight: CGFloat = 34
        let beadSize: CGFloat = 8
        // Bead position mirrors value: top = max.
        let travel = stemHeight - beadSize
        let beadY = travel * (1 - value.clamped01)

        return ZStack(alignment: .top) {
            Rectangle()
                .fill(skin.hairline)
                .frame(width: 1, height: stemHeight)

            bead(size: beadSize)
                .offset(y: beadY)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: value)
        }
        .frame(width: beadSize, height: stemHeight)
    }

    @ViewBuilder
    private func bead(size: CGFloat) -> some View {
        switch style {
        case .black:
            Circle()
                .fill(skin.ink)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 0.5)
        case .chrome:
            Circle()
                .fill(
                    LinearGradient(
                        colors: [skin.chromeTop, skin.chromeBottom],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(Circle().strokeBorder(skin.chromeBorder, lineWidth: 0.5))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 0.5)
        }
    }

    // MARK: - Knob body

    @ViewBuilder
    private var knob: some View {
        switch style {
        case .chrome: chromeKnob
        case .black:  blackKnob
        }
    }

    private var chromeKnob: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [skin.chromeTop, skin.chromeBottom]),
                    center: UnitPoint(x: 0.42, y: 0.32),
                    startRadius: 1,
                    endRadius: diameter * 0.72
                )
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 0.5)
                    .blur(radius: 0.3)
                    .mask(
                        Circle().fill(
                            LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)
                        )
                    )
            )
            .overlay(Circle().strokeBorder(skin.chromeBorder, lineWidth: 0.5))
            .overlay(indicatorDot)
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.12), radius: 7, x: 0, y: 3)
    }

    private var blackKnob: some View {
        ZStack {
            tickRing
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [skin.knobHighlight, skin.knobBody]),
                        center: UnitPoint(x: 0.36, y: 0.30),
                        startRadius: 1,
                        endRadius: diameter * 0.78
                    )
                )
                .overlay(
                    Circle()
                        .inset(by: 1)
                        .stroke(skin.knobRim, lineWidth: 1)
                )
                .overlay(indicatorLine)
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 5)
        }
        .frame(width: diameter + 22, height: diameter + 22)
    }

    // MARK: - Indicators

    private var indicatorDot: some View {
        // 4pt ink dot near the edge at the value angle.
        Circle()
            .fill(skin.ink)
            .frame(width: 4, height: 4)
            .offset(y: -(diameter / 2 - 6))
            .rotationEffect(.degrees(indicatorAngle))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: value)
    }

    private var indicatorLine: some View {
        // 2×10pt line at the edge, in a color that contrasts the knob body.
        Capsule()
            .fill(skin.knobIndicator)
            .frame(width: 2, height: 10)
            .offset(y: -(diameter / 2 - 9))
            .rotationEffect(.degrees(indicatorAngle))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: value)
    }

    private var tickRing: some View {
        let ticks = 28
        let ringRadius = diameter / 2 + 8
        return ZStack {
            ForEach(0..<ticks, id: \.self) { i in
                let t = Double(i) / Double(ticks - 1)
                // Ticks span the same −135…+135 sweep; "passed" ones go ink.
                let passed = t <= value.clamped01
                Capsule()
                    .fill(passed ? skin.ink : skin.hairline)
                    .frame(width: 1.5, height: 2)
                    .offset(y: -ringRadius)
                    .rotationEffect(.degrees(minAngle + (maxAngle - minAngle) * t))
            }
        }
        .animation(.easeOut(duration: 0.15), value: value)
    }
}

/// Scroll-to-adjust with haptic detents, plus double-click reset. Sits on the
/// whole knob column (stem + knob + label).
@available(macOS 14.2, *)
struct KnobScrollInteraction: ViewModifier {
    @Binding var value: Double
    let onReset: () -> Void

    /// Detent grid for haptic ticks: one tick per 5% of travel.
    private static let detentStep = 0.05

    func body(content: Content) -> some View {
        content.overlay(
            ScrollWheelCatcher(
                onScroll: { physicalUpDelta, precise in
                    let pointsPerFullRange: Double = precise ? 260 : 34
                    let old = value
                    let new = (old + physicalUpDelta / pointsPerFullRange).clamped01
                    guard new != old else { return }
                    value = new
                    Self.haptics(old: old, new: new)
                },
                onDoubleClick: {
                    onReset()
                    NSHapticFeedbackManager.defaultPerformer
                        .perform(.levelChange, performanceTime: .default)
                }
            )
        )
    }

    private static func haptics(old: Double, new: Double) {
        let performer = NSHapticFeedbackManager.defaultPerformer
        // Hard stop at either end of travel.
        if (new == 0 && old > 0) || (new == 1 && old < 1) {
            performer.perform(.levelChange, performanceTime: .default)
            return
        }
        // Detent tick when crossing a 5% grid line.
        if Int(old / detentStep) != Int(new / detentStep) {
            performer.perform(.alignment, performanceTime: .default)
        }
    }
}

/// AppKit shim that receives scroll-wheel events for the view it covers,
/// normalizes deltas to "physical upward motion = positive", forwards
/// double-clicks, and refuses to let clicks drag the window.
@available(macOS 14.2, *)
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (Double, Bool) -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onDoubleClick = onDoubleClick
    }

    final class CatcherView: NSView {
        var onScroll: ((Double, Bool) -> Void)?
        var onDoubleClick: (() -> Void)?

        // Clicking a control must never move the panel.
        override var mouseDownCanMoveWindow: Bool { false }

        override func scrollWheel(with event: NSEvent) {
            var delta = Double(event.scrollingDeltaY)
            // scrollingDeltaY is content-direction; undo natural-scrolling
            // inversion so positive always means physical upward motion.
            if event.isDirectionInvertedFromDevice {
                delta = -delta
            }
            guard delta != 0 else { return }
            onScroll?(delta, event.hasPreciseScrollingDeltas)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick?()
            }
            // Swallow single clicks: no window drag, no beep.
        }
    }
}

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
