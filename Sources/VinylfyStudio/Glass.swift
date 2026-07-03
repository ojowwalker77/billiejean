import SwiftUI
import AppKit

// MARK: - VisualEffectBackground (NSVisualEffectView bridge)

/// A behind- or within-window blur, for the fallback glass and the canvas backdrop.
@available(macOS 14.2, *)
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.state = state
    }
}

// MARK: - The one glass recipe

@available(macOS 14.2, *)
extension View {
    /// THE one raised-surface material — every pill, bar, menu, and panel.
    @ViewBuilder
    func floatingGlass<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self
                .clipShape(shape)
                .background(Theme.Palette.raisedTint, in: shape)  // flavor base @ 45%
                .glassEffect(.regular, in: shape)                 // real Liquid Glass
        } else {
            self
                .background {
                    ZStack {
                        VisualEffectBackground(material: .menu, blending: .withinWindow, state: .active)
                        Theme.Palette.popupScrim                  // flavor base @ 60%
                    }
                }
                .clipShape(shape)
                .shadow(color: Theme.Shadow.menu.color, radius: 16, y: 8)
        }
    }

    /// Pills, bars, menus.
    func composerPopupSurface(radius: CGFloat = WindowChrome.radius) -> some View {
        floatingGlass(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Docked side panels / larger glass cards.
    func dockPanelSurface(radius: CGFloat = WindowChrome.panelRadius) -> some View {
        floatingGlass(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// THE one wrapper for every floating chrome pill and bar: identical padding,
    /// radius, glass. Views never add their own surface padding.
    func chromePill() -> some View {
        self
            .padding(.horizontal, WindowChrome.padH)
            .padding(.vertical, WindowChrome.padV)
            .composerPopupSurface(radius: WindowChrome.radius)
    }
}

// MARK: - Canvas backdrop

/// The canvas is solid by default, painted over a behind-window blur so a
/// transparency slider could recede it toward desktop glass. Default 0 = solid.
@available(macOS 14.2, *)
struct PanelBackground: View {
    @AppStorage("billiejean.canvasTransparency") private var transparency = 0.0

    var body: some View {
        let glass = min(1.0, max(0.0, transparency))
        ZStack {
            // A full-window behind-window backdrop keeps the compositor
            // resampling the desktop forever (measured ~25% CPU idle). Only
            // mount it when the user actually dials transparency in.
            if glass > 0.001 {
                VisualEffectBackground(material: .hudWindow, blending: .behindWindow, state: .active)
                Theme.Palette.windowCanvas.opacity(1.0 - 0.65 * glass)
            } else {
                Theme.Palette.windowCanvas
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }
    static func level() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }
}
