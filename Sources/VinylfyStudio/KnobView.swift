import SwiftUI

/// A physical knob with a stem+bead above it. Vertical drag changes the value
/// (full range over 130pt); double-click resets to the default.
@available(macOS 14.2, *)
struct KnobView: View {
    enum Style { case chrome, black }

    let title: String
    let style: Style
    @Binding var value: Double
    let onReset: () -> Void

    /// Diameter of the knob body.
    var diameter: CGFloat { style == .black ? 68 : 36 }

    /// Angle range: −135° … +135°.
    private let minAngle: Double = -135
    private let maxAngle: Double = 135

    @State private var dragStartValue: Double?

    private var indicatorAngle: Double {
        minAngle + (maxAngle - minAngle) * value.clamped01
    }

    var body: some View {
        VStack(spacing: 12) {
            stemAndBead
            knob
            Text(title)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(Theme.secondary)
        }
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
                .fill(Theme.hairline)
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
                .fill(Theme.ink)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 0.5)
        case .chrome:
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.chromeTop, Theme.chromeBottom],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(Circle().strokeBorder(Theme.chromeBorder, lineWidth: 0.5))
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
        // Shared interaction wraps the styled body below.
    }

    private var chromeKnob: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [Theme.chromeTop, Theme.chromeBottom]),
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
            .overlay(Circle().strokeBorder(Theme.chromeBorder, lineWidth: 0.5))
            .overlay(indicatorDot)
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.12), radius: 7, x: 0, y: 3)
            .modifier(KnobInteraction(value: $value, dragStartValue: $dragStartValue, onReset: onReset))
    }

    private var blackKnob: some View {
        ZStack {
            tickRing
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [Theme.knobHighlight, Theme.knobBody]),
                        center: UnitPoint(x: 0.36, y: 0.30),
                        startRadius: 1,
                        endRadius: diameter * 0.78
                    )
                )
                .overlay(
                    Circle()
                        .inset(by: 1)
                        .stroke(Theme.knobRim, lineWidth: 1)
                )
                .overlay(indicatorLine)
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 5)
        }
        .frame(width: diameter + 22, height: diameter + 22)
        .modifier(KnobInteraction(value: $value, dragStartValue: $dragStartValue, onReset: onReset))
    }

    // MARK: - Indicators

    private var indicatorDot: some View {
        // 4pt ink dot near the edge at the value angle.
        Circle()
            .fill(Theme.ink)
            .frame(width: 4, height: 4)
            .offset(y: -(diameter / 2 - 6))
            .rotationEffect(.degrees(indicatorAngle))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: value)
    }

    private var indicatorLine: some View {
        // 2×10pt paper-colored line at the edge.
        Capsule()
            .fill(Theme.paper)
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
                    .fill(passed ? Theme.ink : Theme.hairline)
                    .frame(width: 1.5, height: 2)
                    .offset(y: -ringRadius)
                    .rotationEffect(.degrees(minAngle + (maxAngle - minAngle) * t))
            }
        }
        .animation(.easeOut(duration: 0.15), value: value)
    }
}

/// Vertical-drag + double-click-reset gesture shared by all knob styles.
/// Full range over 130pt of travel.
@available(macOS 14.2, *)
struct KnobInteraction: ViewModifier {
    @Binding var value: Double
    @Binding var dragStartValue: Double?
    let onReset: () -> Void

    private let travel: CGFloat = 130

    func body(content: Content) -> some View {
        content
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let start = dragStartValue ?? value
                        if dragStartValue == nil { dragStartValue = start }
                        // Up = increase.
                        let delta = Double(-g.translation.height / travel)
                        value = (start + delta).clamped01
                    }
                    .onEnded { _ in dragStartValue = nil }
            )
            .onTapGesture(count: 2) { onReset() }
    }
}

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
