import SwiftUI
import AppKit
import NowPlaying

// MARK: - Playback clock (continuous position between 2s polls)

/// Turns the ~2s-cadence now-playing snapshot into a continuous playback
/// position. Snapshots arrive coarsely (`positionSeconds` updates every poll);
/// this class remembers the last polled position + the wall-clock instant it
/// landed, so a `TimelineView` can extrapolate `polled + (now − pollInstant)`
/// while playing. A class (not @State) so TimelineView redraws mutate one shared
/// instance instead of writing view state during render — the MeterSmoother
/// pattern used elsewhere in this file's neighborhood.
@MainActor
final class PlaybackClock {
    private var polledPosition: Double = 0
    private var pollInstant: Date = .now
    private var lastRawPosition: Double?
    private var playing = false
    private var duration: Double = 0

    /// Feed the newest snapshot. Only resets the extrapolation anchor when the
    /// polled position actually changed (or play/pause flipped), so a repeated
    /// identical poll doesn't freeze the creep.
    func ingest(position: Double?, duration: Double?, isPlaying: Bool) {
        self.duration = duration ?? 0
        self.playing = isPlaying
        let pos = position ?? 0
        if lastRawPosition != pos {
            lastRawPosition = pos
            polledPosition = pos
            pollInstant = .now
        }
    }

    /// The extrapolated live position (seconds), clamped to the duration.
    func position(at now: Date = .now) -> Double {
        guard playing else { return clamp(polledPosition) }
        let elapsed = now.timeIntervalSince(pollInstant)
        return clamp(polledPosition + max(0, elapsed))
    }

    /// Live progress 0…1 for the tonearm sweep.
    func progress(at now: Date = .now) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position(at: now) / duration))
    }

    // MARK: Smoothed progress (poll-snap removal, class-held like MeterSmoother)

    private var smoothed: Double = 0
    private var smoothedInit = false
    private var lastFrame: Date?

    /// A poll-snap-free progress for the tonearm: a light exponential follow of
    /// the live extrapolation, so a corrected poll eases in (~0.4s) rather than
    /// jump-snapping. Frame-rate-independent via the real dt between calls.
    func smoothProgress(at now: Date = .now) -> Double {
        let live = progress(at: now)
        guard smoothedInit else {
            smoothed = live; smoothedInit = true; lastFrame = now
            return smoothed
        }
        let dt = max(0, now.timeIntervalSince(lastFrame ?? now))
        lastFrame = now
        // τ ≈ 0.4s → α = 1 − exp(−dt/τ). Snap instantly on large jumps (seek).
        if abs(live - smoothed) > 0.06 {
            let alpha = 1 - exp(-dt / 0.40)
            smoothed += (live - smoothed) * alpha
        } else {
            smoothed = live
        }
        return min(1, max(0, smoothed))
    }

    /// Force the smoothed value (used when a drag/seek commits an exact position).
    func resetSmoothed(to progress: Double) {
        smoothed = min(1, max(0, progress))
        smoothedInit = true
        lastFrame = .now
    }

    private func clamp(_ s: Double) -> Double {
        guard duration > 0 else { return max(0, s) }
        return min(duration, max(0, s))
    }
}

// MARK: - Deck transport button (real 3D, sinks on press)

/// A raised circular deck button. Radial-gradient body (flavor-aware), a 1pt
/// top-edge light stroke masked to the upper half, an inner bottom shadow, and a
/// drop shadow. On press it translates down 1pt, the drop shadow tightens, and
/// the body darkens ~8% — it visibly SINKS. Haptic fires on press-down.
@available(macOS 14.2, *)
struct DeckButtonStyle: ButtonStyle {
    /// Full button diameter.
    var diameter: CGFloat
    /// Glyph point size.
    var glyphSize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        DeckButtonBody(configuration: configuration, diameter: diameter, glyphSize: glyphSize)
    }
}

@available(macOS 14.2, *)
private struct DeckButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let diameter: CGFloat
    let glyphSize: CGFloat

    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        let bodyColor = pressed ? Theme.Palette.buttonBodyPressed : Theme.Palette.buttonBody

        return configuration.label
            .onChange(of: pressed) { _, nowPressed in
                // Haptic the instant the key goes DOWN, like a real switch.
                if nowPressed { Haptics.level() }
            }
            .font(.system(size: glyphSize, weight: .medium))
            .foregroundStyle(hovering ? Theme.Palette.chromeGlyphHover : Theme.Palette.chromeGlyph)
            .frame(width: diameter, height: diameter)
            .background(
                ZStack {
                    // Raised body: catch light top-left → body.
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [Theme.Palette.buttonHighlight, bodyColor]),
                                center: UnitPoint(x: 0.36, y: 0.30),
                                startRadius: 1,
                                endRadius: diameter * 0.82
                            )
                        )
                    // Inner bottom shadow — the lip that reads as depth.
                    Circle()
                        .stroke(Theme.Palette.buttonInnerShadow, lineWidth: 2)
                        .blur(radius: 2)
                        .mask(
                            Circle().fill(
                                LinearGradient(colors: [.clear, .black],
                                               startPoint: .center, endPoint: .bottom)
                            )
                        )
                    // 1pt top-edge light, masked to the upper half.
                    Circle()
                        .strokeBorder(Theme.Palette.buttonEdgeLight, lineWidth: 1)
                        .mask(
                            Circle().fill(
                                LinearGradient(colors: [.black, .clear],
                                               startPoint: .top, endPoint: .center)
                            )
                        )
                }
            )
            .offset(y: pressed ? 1 : 0)
            .shadow(color: .black.opacity(0.30),
                    radius: pressed ? 1.5 : 4,
                    x: 0, y: pressed ? 0.5 : 2)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(ChromeMotion.hover, value: hovering)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: pressed)
    }
}

/// A transport button that reads as a physical deck key. The press haptic fires
/// from `DeckButtonStyle` the instant the key sinks; `action` runs on release.
@available(macOS 14.2, *)
struct DeckButton: View {
    let symbol: String
    let help: String
    var diameter: CGFloat
    var glyphSize: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(DeckButtonStyle(diameter: diameter, glyphSize: glyphSize))
        .help(help)
    }
}

// MARK: - Physical knob (glossy object, palette-driven, size param)

/// The one physical knob used both in the playing panel (44pt) and the command
/// bar (34pt). Glossy body from the flavor palette (light catch top-left → deep
/// body), a 1pt inset rim ring, a drop shadow, a 2×9pt indicator line, and a thin
/// accent value-arc riding OUTSIDE the knob body so the knob itself stays clean.
/// Scroll-to-adjust, double-click reset, and detent haptics are preserved.
@available(macOS 14.2, *)
struct PhysicalKnob: View {
    let help: String
    @Binding var value: Double
    let onReset: () -> Void

    var size: CGFloat = WindowChrome.controlHeight
    var label: String? = nil

    @State private var hovering = false

    private let minAngle: Double = -135
    private let maxAngle: Double = 135
    private static let detentStep = 0.05

    private var indicatorAngle: Double {
        minAngle + (maxAngle - minAngle) * value.clamped01
    }

    var body: some View {
        VStack(spacing: 6) {
            knob
            if let label {
                Text(label)
                    .font(WindowChrome.captionFont)
                    .foregroundStyle(Theme.Palette.count)
                    .lineLimit(1)
            }
        }
    }

    private var knob: some View {
        ZStack {
            // Accent value-arc OUTSIDE the body: radius +4pt, 3pt round-cap line.
            Circle()
                .trim(from: 0, to: value.clamped01 * (maxAngle - minAngle) / 360.0)
                .stroke(Theme.Palette.accent,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(90 + minAngle))
                .frame(width: size + 8, height: size + 8)
                .animation(ChromeMotion.hover, value: value)

            // Glossy body: catch light top-left → deep body, 1pt inset rim.
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [Theme.Palette.knobHighlight, Theme.Palette.knobBody]),
                        center: UnitPoint(x: 0.36, y: 0.30),
                        startRadius: 1,
                        endRadius: size * 0.78
                    )
                )
                .overlay(
                    Circle().inset(by: 1).stroke(Theme.Palette.knobRim, lineWidth: 1)
                )
                .overlay(Circle().fill(hovering ? Theme.Palette.hoverWash : .clear))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 5)

            // Indicator line: 2×9pt, contrasting palette token.
            Capsule()
                .fill(Theme.Palette.knobIndicator)
                .frame(width: 2, height: 9)
                .offset(y: -(size / 2 - 7))
                .rotationEffect(.degrees(indicatorAngle))
                .animation(ChromeMotion.hover, value: value)
        }
        .frame(width: size + 8, height: size + 8)
        .contentShape(Circle())
        .overlay(
            KnobScrollCatcher(
                onScroll: { delta, precise in
                    let pointsPerFullRange: Double = precise ? 260 : 34
                    let old = value
                    let new = (old + delta / pointsPerFullRange).clamped01
                    guard new != old else { return }
                    value = new
                    Self.haptics(old: old, new: new)
                },
                onDoubleClick: {
                    onReset()
                    Haptics.level()
                }
            )
        )
        .onHover { hovering = $0 }
        .animation(ChromeMotion.hover, value: hovering)
        .help(help)
    }

    private static func haptics(old: Double, new: Double) {
        let performer = NSHapticFeedbackManager.defaultPerformer
        if (new == 0 && old > 0) || (new == 1 && old < 1) {
            performer.perform(.levelChange, performanceTime: .default)
            return
        }
        if Int(old / detentStep) != Int(new / detentStep) {
            performer.perform(.alignment, performanceTime: .default)
        }
    }
}

/// Scroll/double-click catcher shared by the physical knob (same behavior as the
/// widget's KnobView catcher, kept local so the widget file stays untouched).
@available(macOS 14.2, *)
private struct KnobScrollCatcher: NSViewRepresentable {
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
    }
}
