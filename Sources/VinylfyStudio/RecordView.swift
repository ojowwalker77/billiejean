import SwiftUI

/// The hero: a glossy vinyl record with an artwork label, fixed specular sheen,
/// inertial spin, bypass "cold" state, and a static tonearm that lifts when
/// the engine is stopped.
@available(macOS 14.2, *)
struct RecordView: View {
    var model: StudioViewModel

    /// Disc diameter.
    private let diameter: CGFloat = 232

    var body: some View {
        // The spin driver: TimelineView accumulates angle with inertial ramp so
        // the disc spins up / coasts down and never hard-starts.
        TimelineView(.animation) { context in
            let angle = spinner.angle(at: context.date, spinning: model.isSpinning)
            ZStack {
                // --- Rotating disc (body + grooves + label) ---
                disc
                    .rotationEffect(.degrees(angle))

                // --- Fixed specular sheen above the rotating disc ---
                sheen
                    .allowsHitTesting(false)
            }
            .frame(width: diameter, height: diameter)
            .overlay(alignment: .topTrailing) {
                Tonearm(engaged: model.isRunning, discDiameter: diameter)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: - Disc

    private var disc: some View {
        let base = model.bypass ? model.recordColor.desaturated : model.recordColor
        return ZStack {
            Circle()
                .fill(bodyGradient(base: base))
                .overlay(
                    Circle().strokeBorder(base.darkened(by: 0.6), lineWidth: 1)
                )
            grooves
            label
        }
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 5)
    }

    private func bodyGradient(base: Color) -> RadialGradient {
        // center → rim: near-black label edge, darkened mid, base at 75%, darkened rim.
        RadialGradient(
            gradient: Gradient(stops: [
                .init(color: Color(hex: 0x14100E), location: 0.00),
                .init(color: Color(hex: 0x14100E), location: 0.19),
                .init(color: base.darkened(by: 0.35), location: 0.48),
                .init(color: base, location: 0.75),
                .init(color: base.darkened(by: 0.5), location: 1.0),
            ]),
            center: .center,
            startRadius: 0,
            endRadius: diameter / 2
        )
    }

    private var grooves: some View {
        let labelRadius = diameter * 0.19
        let rimRadius = diameter / 2 - 3
        let count = 14
        return ZStack {
            ForEach(0..<count, id: \.self) { i in
                let t = Double(i) / Double(count - 1)
                let r = labelRadius + (rimRadius - labelRadius) * t
                Circle()
                    .stroke(
                        i.isMultiple(of: 2)
                            ? Color.white.opacity(0.05)
                            : Color.black.opacity(0.06),
                        lineWidth: 0.5
                    )
                    .frame(width: r * 2, height: r * 2)
            }
        }
        .allowsHitTesting(false)
    }

    private var label: some View {
        let labelDiameter = diameter * 0.38
        return ZStack {
            if let art = model.artworkImage {
                Image(nsImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: labelDiameter, height: labelDiameter)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Theme.ink)
                    .frame(width: labelDiameter, height: labelDiameter)
                    .overlay(
                        Text("VINYLFY")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(Theme.paper)
                    )
            }
        }
        // Label ring
        .overlay(
            Circle()
                .strokeBorder(Theme.ink, lineWidth: 1.5)
                .frame(width: labelDiameter, height: labelDiameter)
        )
        // Center hole
        .overlay(
            Circle()
                .fill(Theme.paper)
                .frame(width: 5, height: 5)
                .overlay(
                    Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 0.5, x: 0, y: 0.5)
        )
    }

    // MARK: - Fixed specular sheen

    private var sheen: some View {
        // Two soft angular white streaks that DO NOT rotate — read as glossy
        // plastic under fixed room light.
        Circle()
            .fill(
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .white.opacity(0.12), location: 0.08),
                        .init(color: .clear, location: 0.20),
                        .init(color: .clear, location: 0.48),
                        .init(color: .white.opacity(0.10), location: 0.58),
                        .init(color: .clear, location: 0.70),
                        .init(color: .clear, location: 1.00),
                    ]),
                    center: .center,
                    angle: .degrees(-35)
                )
            )
            .blendMode(.screen)
    }

    // MARK: - Spin state (persisted across frames)

    @State private var spinner = InertialSpinner()
}

/// Accumulates rotation angle with an exponential approach toward a target
/// angular velocity, giving spin-up / coast-down inertia. Reference-frame
/// stored via a class so TimelineView redraws mutate the same instance.
@available(macOS 14.2, *)
final class InertialSpinner {
    private var lastTimestamp: Date?
    private var angle: Double = 0          // degrees
    private var velocity: Double = 0       // degrees / second

    /// 1 revolution / 1.8s while playing.
    private let targetVelocity: Double = 360.0 / 1.8
    /// Exponential approach time constant.
    private let tau: Double = 0.6

    func angle(at now: Date, spinning: Bool) -> Double {
        defer { lastTimestamp = now }
        guard let last = lastTimestamp else { return angle }
        let dt = min(0.1, max(0, now.timeIntervalSince(last)))
        guard dt > 0 else { return angle }

        let target = spinning ? targetVelocity : 0
        // Exponential approach: v += (target - v) * (1 - e^(-dt/tau))
        let k = 1 - exp(-dt / tau)
        velocity += (target - velocity) * k
        angle += velocity * dt
        if angle >= 360 { angle = angle.truncatingRemainder(dividingBy: 360) }
        return angle
    }
}

/// Minimalist tonearm from the top-right. Static while engaged; rotates ~14°
/// away from the disc around its pivot when the engine is stopped.
@available(macOS 14.2, *)
struct Tonearm: View {
    var engaged: Bool
    var discDiameter: CGFloat

    var body: some View {
        // Pivot near the top-right, just outside the disc.
        let center = CGPoint(x: discDiameter / 2, y: discDiameter / 2)
        let pivot = CGPoint(x: discDiameter + 4, y: -8)
        // Head rests at the disc's ~2 o'clock outer-third: up-and-right of center.
        // 2 o'clock ≈ 60° above the +x axis; y is down in SwiftUI so subtract.
        let seat = discDiameter * 0.34
        let headPoint = CGPoint(
            x: center.x + cos(.pi / 3) * seat,
            y: center.y - sin(.pi / 3) * seat
        )
        // Angle of the arm line, for orienting the head along it.
        let armAngle = Angle.radians(atan2(headPoint.y - pivot.y, headPoint.x - pivot.x))

        ZStack {
            // Arm line
            Path { p in
                p.move(to: pivot)
                p.addLine(to: headPoint)
            }
            .stroke(Theme.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            // Head
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.ink)
                .frame(width: 10, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 4, height: 6)
                        .offset(x: -1.5, y: -3)
                )
                .rotationEffect(armAngle + .degrees(90))
                .position(headPoint)
        }
        .frame(width: discDiameter, height: discDiameter)
        .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
        // Lift the whole arm away from the disc when stopped.
        .rotationEffect(.degrees(engaged ? 0 : -14), anchor: .topTrailing)
        .animation(.easeInOut(duration: 0.5), value: engaged)
    }
}
