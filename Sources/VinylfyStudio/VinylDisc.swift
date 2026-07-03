import SwiftUI
import AppKit
import NowPlaying

// MARK: - Shared disc drawing

/// A vinyl disc: dark body with a dominant-color gradient (once artwork arrives),
/// groove rings, a circular artwork label at 38%, and a center hole. Simplified
/// and static (spin driven externally via `rotationEffect`). Reused by both the
/// library cell and — at a larger size — the player.
@available(macOS 14.2, *)
struct VinylDiscFace: View {
    let diameter: CGFloat
    let artwork: NSImage?
    /// Dominant color once artwork resolves; nil = flavor-correct placeholder.
    let dominant: Color?
    /// When true, body is desaturated (bypass "cold").
    var cold: Bool = false

    private var base: Color {
        let c = dominant ?? Theme.Palette.tint(4)   // flavor blue as calm placeholder
        return cold ? c.desaturated : c
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(bodyGradient)
                .overlay(Circle().strokeBorder(base.darkened(by: 0.6), lineWidth: 1))
            grooves
            label
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }

    private var bodyGradient: RadialGradient {
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
                        i.isMultiple(of: 2) ? Color.white.opacity(0.05) : Color.black.opacity(0.06),
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
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: labelDiameter, height: labelDiameter)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(hex: 0x1A1614))
                    .frame(width: labelDiameter, height: labelDiameter)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: labelDiameter * 0.28, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.55))
                    )
            }
        }
        .overlay(
            Circle()
                .strokeBorder(Color(hex: 0x14100E), lineWidth: 1.5)
                .frame(width: labelDiameter, height: labelDiameter)
        )
        .overlay(
            Circle()
                .fill(Color(hex: 0x0A0807))
                .frame(width: max(4, diameter * 0.022), height: max(4, diameter * 0.022))
                .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 0.5))
        )
    }
}

// MARK: - Sleeve cell (playlists AND tracks)

/// A cover-art SLEEVE in a grid — playlists read as record covers, not discs.
/// A square cover; on hover the sleeve lifts and a dark vinyl disc peeks out of
/// its right edge (behind the cover), and a play button fades in bottom-right.
/// Tapping the cover and tapping the play button are separate actions.
@available(macOS 14.2, *)
struct SleeveCell: View {
    let title: String
    let subtitle: String
    let artwork: NSImage?
    /// Cover tap (library: open song grid · songGrid: play track).
    let onOpen: () -> Void
    /// Play-button tap (library: play playlist · songGrid: play track).
    let onPlay: () -> Void
    let onAppear: () -> Void

    var size: CGFloat = 168

    @State private var hovering = false

    private var coverRadius: CGFloat { 8 }

    var body: some View {
        VStack(spacing: 10) {
            cover
                .frame(width: size, height: size)
                .scaleEffect(hovering ? 1.03 : 1.0)
                .shadow(color: .black.opacity(hovering ? 0.34 : 0.18),
                        radius: hovering ? 18 : 10, y: hovering ? 9 : 5)
                .animation(ChromeMotion.hover, value: hovering)

            VStack(spacing: 2) {
                Text(title)
                    .font(WindowChrome.labelFont)
                    .foregroundStyle(Theme.Palette.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(WindowChrome.sublabelFont)
                    .foregroundStyle(Theme.Palette.count)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: size)
        }
        .onHover { hovering = $0 }
        .onAppear(perform: onAppear)
        .help(title)
    }

    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            // Peek disc — behind the cover, sliding out the right edge on hover.
            peekDisc
                .frame(width: size, height: size)
                .offset(x: hovering ? size * 0.14 : 0)
                .opacity(hovering ? 1 : 0)
                .animation(ChromeMotion.hover, value: hovering)
                .allowsHitTesting(false)

            // Opaque cover on top.
            coverArt
                .clipShape(RoundedRectangle(cornerRadius: coverRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: coverRadius, style: .continuous)
                        .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: coverRadius, style: .continuous))
                .onTapGesture { Haptics.tap(); onOpen() }

            // Play button — bottom-right, fades in on hover.
            SleevePlayButton(action: { Haptics.tap(); onPlay() })
                .padding(10)
                .opacity(hovering ? 1 : 0)
                .scaleEffect(hovering ? 1 : 0.8)
                .animation(ChromeMotion.hover, value: hovering)
                .allowsHitTesting(hovering)
        }
        // NO clip here: the peek disc must stay visible PAST the cover's right
        // edge — the cover itself is opaque, so the disc only reads outside it.
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var coverArt: some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
        } else {
            // Backed by the solid canvas color so the placeholder is OPAQUE —
            // a translucent surface would let the peek disc ghost through it.
            RoundedRectangle(cornerRadius: coverRadius, style: .continuous)
                .fill(Theme.Palette.windowCanvas)
                .overlay(
                    RoundedRectangle(cornerRadius: coverRadius, style: .continuous)
                        .fill(Theme.Palette.rowFill)
                )
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.22, weight: .light))
                        .foregroundStyle(Theme.Palette.chromeGlyphDim)
                )
        }
    }

    /// A plain dark decorative record edge — NOT a full VinylDiscFace (§V3):
    /// a near-black circle with a few faint concentric groove rings.
    private var peekDisc: some View {
        ZStack {
            Circle().fill(Color(hex: 0x14100E))
            ForEach(0..<3, id: \.self) { i in
                let t = Double(i + 1) / 4.0
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                    .padding(size * 0.5 * (1 - t))
            }
            // Small label + spindle hint for realism.
            Circle()
                .fill(Color(hex: 0x1A1614))
                .frame(width: size * 0.30, height: size * 0.30)
            Circle()
                .fill(Color(hex: 0x0A0807))
                .frame(width: max(4, size * 0.02), height: max(4, size * 0.02))
        }
    }
}

/// The glass play button that appears on a hovered sleeve.
@available(macOS 14.2, *)
struct SleevePlayButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(WindowChrome.iconFont)
                .foregroundStyle(hovering ? Theme.Palette.chromeGlyphHover : Theme.Palette.body)
                .frame(width: WindowChrome.controlHeight, height: WindowChrome.controlHeight)
                .composerPopupSurface(radius: WindowChrome.controlHeight / 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ChromeMotion.hover, value: hovering)
        .help("Play")
    }
}

// MARK: - Player hero record

/// The big crisp turntable record for the PLAYER state: artwork label,
/// dominant-color body, hard rim, fixed non-rotating sheen, inertial spin.
/// No built-in tonearm — the turntable canvas overlays its own larger arm.
@available(macOS 14.2, *)
struct PlayerRecord: View {
    let diameter: CGFloat
    let artwork: NSImage?
    let dominant: Color?
    let spinning: Bool
    var cold: Bool = false

    @State private var spinner = InertialSpinner()

    private var base: Color {
        let c = dominant ?? Theme.Palette.tint(4)
        return cold ? c.desaturated : c
    }

    var body: some View {
        TimelineView(.animation) { context in
            let angle = spinner.angle(at: context.date, spinning: spinning)
            ZStack {
                VinylDiscFace(diameter: diameter, artwork: artwork, dominant: dominant, cold: cold)
                    .rotationEffect(.degrees(angle))
                // Hard rim for crispness (matches RecordView's rim discipline).
                Circle()
                    .strokeBorder(base.darkened(by: 0.6), lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)
                    .allowsHitTesting(false)
                sheen
                    .allowsHitTesting(false)
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.28), radius: diameter * 0.05, y: diameter * 0.03)
        }
        .frame(width: diameter, height: diameter)
    }

    private var sheen: some View {
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
}
