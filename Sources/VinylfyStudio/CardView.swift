import SwiftUI

/// The card — the whole widget surface. Draws its own rounded background in
/// the active skin, clips everything inside, and lays out the record,
/// controls, and progress.
@available(macOS 14.2, *)
struct CardView: View {
    @Bindable var model: StudioViewModel

    private var skin: Skin { model.skin }

    var body: some View {
        ZStack {
            // Surface with a subtle vertical luminance gradient, lighter at top.
            LinearGradient(
                colors: [skin.cardTop, skin.cardMid, skin.cardBottom],
                startPoint: .top, endPoint: .bottom
            )

            if skin.grain {
                WoodGrain()
            }

            content
        }
        .frame(width: Theme.cardWidth, height: Theme.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(skin.cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 24, x: 0, y: 12)
        .animation(.easeInOut(duration: 0.3), value: skin.kind)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.startError {
            errorState(error)
        } else {
            VStack(spacing: 0) {
                topBar
                RecordView(model: model)
                    .frame(height: 232)
                    .padding(.top, 6)

                trackLine
                    .padding(.top, 10)

                Spacer(minLength: 8)

                controlsRow

                Spacer(minLength: 8)

                ProgressRow(
                    position: model.positionSeconds,
                    duration: model.durationSeconds,
                    color: model.recordColor,
                    skin: skin
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Top bar (status dot + A/B)

    private var topBar: some View {
        HStack {
            StatusDot(running: model.isRunning, color: model.recordColor, skin: skin)
                .onTapGesture { model.toggleRunning() }
            Spacer()
            bypassButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var bypassButton: some View {
        // "A/B" monogram: filled ink capsule when in ORIGINAL (bypass) mode.
        Text("A/B")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(model.bypass ? skin.cardMid : skin.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(model.bypass ? skin.ink : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(skin.hairline, lineWidth: model.bypass ? 0 : 1)
            )
            .contentShape(Capsule())
            .onTapGesture { model.toggleBypass() }
    }

    // MARK: - Track line

    private var trackLine: some View {
        Text(model.trackLine ?? " ")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(skin.ink)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: Theme.cardWidth - 32)
            .id(model.trackLine ?? "")
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.35), value: model.trackLine)
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            KnobView(title: "Noise", style: .chrome, skin: skin,
                     value: $model.noise, onReset: model.resetNoise)
            Spacer()
            KnobView(title: "Main", style: .black, skin: skin,
                     value: $model.main, onReset: model.resetMain)
            Spacer()
            KnobView(title: "Volume", style: .chrome, skin: skin,
                     value: $model.volume, onReset: model.resetVolume)
        }
        .frame(width: 200)
    }

    // MARK: - Error state

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Vinylfy")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(skin.ink)
            Text(message)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color(hex: 0xC0392B))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Text("Retry")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(skin.cardMid)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Capsule().fill(skin.ink))
                .onTapGesture { model.start() }
            Spacer()
        }
        .frame(width: Theme.cardWidth, height: Theme.cardHeight)
    }
}

/// Static wood-grain texture: soft vertical streaks and two plank seams.
/// Deterministic — no randomness, so it never shimmers across renders.
@available(macOS 14.2, *)
private struct WoodGrain: View {
    // (x fraction, width, dark opacity) — hand-placed streaks.
    private static let streaks: [(Double, CGFloat, Double)] = [
        (0.08, 26, 0.045), (0.19, 14, 0.03), (0.31, 34, 0.05),
        (0.44, 18, 0.035), (0.57, 30, 0.045), (0.69, 12, 0.03),
        (0.80, 28, 0.05), (0.93, 16, 0.035),
    ]
    // Light counter-streaks for depth.
    private static let lights: [(Double, CGFloat, Double)] = [
        (0.14, 10, 0.04), (0.50, 12, 0.035), (0.87, 9, 0.04),
    ]
    // Plank seams (x fraction).
    private static let seams: [Double] = [0.335, 0.665]

    var body: some View {
        Canvas { ctx, size in
            for (fx, width, opacity) in Self.streaks {
                let rect = CGRect(x: size.width * fx - width / 2, y: 0, width: width, height: size.height)
                ctx.fill(Path(rect), with: .color(.black.opacity(opacity)))
            }
            for (fx, width, opacity) in Self.lights {
                let rect = CGRect(x: size.width * fx - width / 2, y: 0, width: width, height: size.height)
                ctx.fill(Path(rect), with: .color(.white.opacity(opacity)))
            }
            for fx in Self.seams {
                let rect = CGRect(x: size.width * fx, y: 0, width: 1, height: size.height)
                ctx.fill(Path(rect), with: .color(.black.opacity(0.10)))
            }
        }
        .blur(radius: 1.2)
        .allowsHitTesting(false)
    }
}

/// Status dot — running glows in the record color; stopped is muted.
@available(macOS 14.2, *)
struct StatusDot: View {
    var running: Bool
    var color: Color
    var skin: Skin

    var body: some View {
        Circle()
            .fill(running ? color : skin.stoppedDot)
            .frame(width: 8, height: 8)
            .shadow(color: running ? color.opacity(0.7) : .clear, radius: running ? 4 : 0)
            .contentShape(Rectangle().inset(by: -6))
            .animation(.easeInOut(duration: 0.3), value: running)
    }
}

/// Bottom progress row: elapsed — thin bar — total.
@available(macOS 14.2, *)
struct ProgressRow: View {
    var position: Double?
    var duration: Double?
    var color: Color
    var skin: Skin

    private var fraction: Double {
        guard let position, let duration, duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.timeString(position))
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(skin.hairline).frame(height: 2)
                    Capsule().fill(color)
                        .frame(width: geo.size.width * fraction, height: 2)
                        .animation(.easeInOut(duration: 0.4), value: fraction)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 10)
            Text(Self.timeString(duration))
                .frame(width: 34, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .regular, design: .monospaced))
        .foregroundStyle(skin.secondary)
    }

    private static func timeString(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–:––" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
