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
    /// Hardware-orange glyph (the one colored key in a cluster).
    var accentGlyph = false

    func makeBody(configuration: Configuration) -> some View {
        DeckButtonBody(configuration: configuration, diameter: diameter,
                       glyphSize: glyphSize, accentGlyph: accentGlyph)
    }
}

@available(macOS 14.2, *)
private struct DeckButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let diameter: CGFloat
    let glyphSize: CGFloat
    var accentGlyph = false

    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed

        return configuration.label
            .onChange(of: pressed) { _, nowPressed in
                // Haptic the instant the key goes DOWN, like a real switch.
                if nowPressed { Haptics.level() }
            }
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(glyphColor)
            .scaleEffect(pressed ? 0.96 : 1)
            .modifier(SkeuoRaisedCircle(diameter: diameter, pressed: pressed))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(ChromeMotion.hover, value: hovering)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: pressed)
    }

    private var glyphColor: Color {
        if accentGlyph { return Theme.Palette.hwOrange }
        return hovering ? Theme.Palette.body : Theme.Palette.printedInk
    }
}

/// A transport button that reads as a physical deck key. The press haptic fires
/// from `DeckButtonStyle` the instant the key sinks; `action` runs on release.
/// `accentGlyph` marks the primary key with the hardware orange (Braun-style —
/// exactly one colored control per cluster).
@available(macOS 14.2, *)
struct DeckButton: View {
    let symbol: String
    let help: String
    var diameter: CGFloat
    var glyphSize: CGFloat
    var accentGlyph = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(DeckButtonStyle(diameter: diameter, glyphSize: glyphSize, accentGlyph: accentGlyph))
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
    /// Engrave a tick scale on the faceplate around the knob (playing panel).
    var printedScale = false

    @State private var hovering = false

    private let minAngle: Double = -135
    private let maxAngle: Double = 135
    private static let detentStep = 0.05

    private var indicatorAngle: Double {
        minAngle + (maxAngle - minAngle) * value.clamped01
    }

    /// Extra canvas so the printed scale fits around the knob.
    private var frameSize: CGFloat { size + (printedScale ? 18 : 8) }

    var body: some View {
        VStack(spacing: 6) {
            knob
            if let label {
                Text(label)
                    .font(WindowChrome.captionFont)
                    .foregroundStyle(Theme.Palette.printedInk)
                    .lineLimit(1)
            }
        }
    }

    private var knob: some View {
        ZStack {
            if printedScale {
                tickScale
            }

            // Machined body: knurled skirt with a domed cap and a painted pointer.
            ZStack {
                // Skirt with knurling — tiny radial grip cuts around the edge.
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [Theme.Palette.ctrlLight, Theme.Palette.ctrlDark]),
                            center: UnitPoint(x: 0.38, y: 0.30),
                            startRadius: 1,
                            endRadius: size * 0.80
                        )
                    )
                knurling
                    .rotationEffect(.degrees(indicatorAngle))
                // Domed cap — the raised center that catches the room light.
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [Theme.Palette.ctrlLight, Theme.Palette.ctrlDark]),
                            center: UnitPoint(x: 0.34, y: 0.26),
                            startRadius: 0,
                            endRadius: size * 0.42
                        )
                    )
                    .frame(width: size * 0.68, height: size * 0.68)
                    .innerShadow(Circle(), color: Theme.Palette.insetHi.opacity(0.7),
                                 lineWidth: 1, blur: 0.8, y: -0.6)
                    .shadow(color: .black.opacity(0.25), radius: 1.2, y: 1)
                // Painted pointer on the cap, turned by the value.
                Capsule()
                    .fill(Theme.Palette.body)
                    .frame(width: 2, height: size * 0.26)
                    .offset(y: -size * 0.19)
                    .rotationEffect(.degrees(indicatorAngle))
                    .animation(ChromeMotion.hover, value: value)
                Circle().strokeBorder(Theme.Palette.bezelDark, lineWidth: 1)
                Circle().fill(hovering ? Theme.Palette.hoverWash : .clear)
            }
            .frame(width: size, height: size)
            .innerShadow(Circle(), color: Theme.Palette.insetLo.opacity(0.7),
                         lineWidth: 1.5, blur: 1.5, x: 0.8, y: 1.5)
            .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.22), radius: 6, y: 3.5)
        }
        .frame(width: frameSize, height: frameSize)
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

    /// Knurling: alternating grip cuts around the skirt (they rotate with the knob).
    private var knurling: some View {
        let cuts = size >= 40 ? 36 : 24
        return ZStack {
            ForEach(0..<cuts, id: \.self) { i in
                Capsule()
                    .fill(i.isMultiple(of: 2)
                          ? Theme.Palette.insetLo.opacity(0.45)
                          : Theme.Palette.insetHi.opacity(0.35))
                    .frame(width: 1, height: size * 0.10)
                    .offset(y: -size / 2 + size * 0.06)
                    .rotationEffect(.degrees(Double(i) / Double(cuts) * 360))
            }
        }
        .allowsHitTesting(false)
    }

    /// Engraved faceplate scale: eleven ticks over the sweep, ends slightly longer.
    private var tickScale: some View {
        ZStack {
            ForEach(0..<11, id: \.self) { i in
                let t = Double(i) / 10.0
                let isEnd = i == 0 || i == 10
                Capsule()
                    .fill(Theme.Palette.printedInk.opacity(isEnd ? 0.8 : 0.45))
                    .frame(width: 1, height: isEnd ? 5 : 3)
                    .offset(y: -(size / 2 + 6))
                    .rotationEffect(.degrees(minAngle + (maxAngle - minAngle) * t))
            }
        }
        .allowsHitTesting(false)
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
