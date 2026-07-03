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

// MARK: - Library disc cell

/// A playlist as a disc in the wall: static disc, lazy artwork, hover lifts +
/// slow spin, click → play. Name + track count below.
@available(macOS 14.2, *)
struct LibraryDiscCell: View {
    let playlist: MusicPlaylist
    let artwork: NSImage?
    let dominant: Color?
    let onAppear: () -> Void
    let onPlay: () -> Void

    @State private var hovering = false
    private let discSize: CGFloat = 150

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.animation(paused: !hovering)) { context in
                let angle = hovering
                    ? (context.date.timeIntervalSinceReferenceDate * 24).truncatingRemainder(dividingBy: 360)
                    : 0
                VinylDiscFace(diameter: discSize, artwork: artwork, dominant: dominant)
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: discSize, height: discSize)
            .scaleEffect(hovering ? 1.04 : 1.0)
            .shadow(color: .black.opacity(hovering ? 0.32 : 0.16),
                    radius: hovering ? 16 : 9, y: hovering ? 8 : 5)
            .animation(ChromeMotion.hover, value: hovering)

            VStack(spacing: 2) {
                Text(playlist.name)
                    .font(WindowChrome.labelFont)
                    .foregroundStyle(Theme.Palette.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(playlist.trackCount) track\(playlist.trackCount == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.count)
            }
            .frame(width: 170)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { Haptics.tap(); onPlay() }
        .onAppear(perform: onAppear)
        .help(playlist.name)
    }
}

// MARK: - Player hero record

/// The big spinning record for the PLAYER state: artwork label, dominant-color
/// body, fixed sheen, inertial spin driven by playback, static tonearm.
@available(macOS 14.2, *)
struct PlayerRecord: View {
    let diameter: CGFloat
    let artwork: NSImage?
    let dominant: Color?
    let spinning: Bool
    let engaged: Bool
    var cold: Bool = false

    @State private var spinner = InertialSpinner()

    var body: some View {
        TimelineView(.animation) { context in
            let angle = spinner.angle(at: context.date, spinning: spinning)
            ZStack {
                VinylDiscFace(diameter: diameter, artwork: artwork, dominant: dominant, cold: cold)
                    .rotationEffect(.degrees(angle))
                    .shadow(color: .black.opacity(0.22), radius: diameter * 0.05, y: diameter * 0.025)
                sheen
                    .allowsHitTesting(false)
            }
            .frame(width: diameter, height: diameter)
            .overlay(alignment: .topTrailing) {
                Tonearm(engaged: engaged, discDiameter: diameter, armColor: Theme.Palette.body)
            }
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
