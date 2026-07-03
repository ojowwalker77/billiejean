import SwiftUI

/// The paper card — the whole widget surface. Draws its own rounded background,
/// clips everything inside, and lays out the record, controls, and progress.
@available(macOS 14.2, *)
struct CardView: View {
    @Bindable var model: StudioViewModel

    var body: some View {
        ZStack {
            // Paper with a subtle vertical luminance gradient, lighter at top.
            LinearGradient(
                colors: [Theme.paperTop, Theme.paper, Theme.paperBottom],
                startPoint: .top, endPoint: .bottom
            )

            content
        }
        .frame(width: Theme.cardWidth, height: Theme.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(Theme.hairline.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 24, x: 0, y: 12)
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
                    color: model.recordColor
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Top bar (status dot + A/B)

    private var topBar: some View {
        HStack {
            StatusDot(running: model.isRunning, color: model.recordColor)
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
            .foregroundStyle(model.bypass ? Theme.paper : Theme.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(model.bypass ? Theme.ink : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(Theme.hairline, lineWidth: model.bypass ? 0 : 1)
            )
            .contentShape(Capsule())
            .onTapGesture { model.toggleBypass() }
    }

    // MARK: - Track line

    private var trackLine: some View {
        Text(model.trackLine ?? " ")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.ink)
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
            KnobView(title: "Noise", style: .chrome,
                     value: $model.noise, onReset: model.resetNoise)
            Spacer()
            KnobView(title: "Main", style: .black,
                     value: $model.main, onReset: model.resetMain)
            Spacer()
            KnobView(title: "Volume", style: .chrome,
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
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color(hex: 0xC0392B))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Text("Retry")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.paper)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Capsule().fill(Theme.ink))
                .onTapGesture { model.start() }
            Spacer()
        }
        .frame(width: Theme.cardWidth, height: Theme.cardHeight)
    }
}

/// Status dot — running glows in the record color; stopped is muted.
@available(macOS 14.2, *)
struct StatusDot: View {
    var running: Bool
    var color: Color

    var body: some View {
        Circle()
            .fill(running ? color : Theme.stoppedDot)
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
                    Capsule().fill(Theme.hairline).frame(height: 2)
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
        .foregroundStyle(Theme.secondary)
    }

    private static func timeString(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–:––" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
