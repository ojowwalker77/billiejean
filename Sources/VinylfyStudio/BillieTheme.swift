import SwiftUI
import AppKit

// MARK: - Layer 1: ThemeFlavor (a theme as pure data)

/// A complete theme as data. Slot semantics follow Catppuccin's model:
/// `text` > `subtext1/0` > `overlay2/1/0` > `surface2/1/0` > `base`/`mantle`/`crust`.
/// Adding a theme is a new `ThemeFlavor` + one `Flavor` case — never a view change.
struct ThemeFlavor {
    let isDark: Bool
    let text, subtext1, subtext0: NSColor
    let overlay2, overlay1, overlay0: NSColor
    let surface2, surface1, surface0: NSColor
    let base, mantle, crust: NSColor
    let accent: NSColor       // THE one accent: selection, active tool, primary action
    let info: NSColor         // informational tint
    let tints: [NSColor]      // user-pickable element colors (red, orange, yellow, green, blue, purple)
}

/// The four shipped flavors. Selecting one is a persisted `@AppStorage` string.
enum Flavor: String, CaseIterable, Identifiable {
    case bonsaiDark
    case bonsaiLight
    case mocha
    case latte

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bonsaiDark:  return "Bonsai Dark"
        case .bonsaiLight: return "Bonsai Light"
        case .mocha:       return "Catppuccin Mocha"
        case .latte:       return "Catppuccin Latte"
        }
    }

    var flavor: ThemeFlavor {
        switch self {
        case .bonsaiDark:  return .bonsaiDark
        case .bonsaiLight: return .bonsaiLight
        case .mocha:       return .mocha
        case .latte:       return .latte
        }
    }

    /// The NSAppearance the window must adopt so system controls resolve correctly.
    var appearance: NSAppearance? {
        NSAppearance(named: flavor.isDark ? .darkAqua : .aqua)
    }
}

extension NSColor {
    /// Blend toward black by `amount` (0…1) in sRGB — for pressed-state darkening.
    func darkened(by amount: Double) -> NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        let t = CGFloat(min(1, max(0, amount)))
        return NSColor(
            srgbRed: c.redComponent * (1 - t),
            green: c.greenComponent * (1 - t),
            blue: c.blueComponent * (1 - t),
            alpha: c.alphaComponent
        )
    }
}

private func ns(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: 1.0
    )
}

extension ThemeFlavor {
    /// Bonsai Dark — stone ink on pure black; accent = system control accent.
    static let bonsaiDark = ThemeFlavor(
        isDark: true,
        text: ns(0xE3E2DD), subtext1: ns(0xA5A4A0), subtext0: ns(0x9B9A96),
        overlay2: ns(0x807F7C), overlay1: ns(0x585856), overlay0: ns(0x403F3E),
        surface2: ns(0x2A2A28), surface1: ns(0x1F1F1E), surface0: ns(0x161615),
        base: ns(0x000000), mantle: ns(0x2B2B2B), crust: ns(0x000000),
        accent: .controlAccentColor,
        info: ns(0x7A9BC4),
        tints: [ns(0xD97A74), ns(0xD99A6C), ns(0xD4B96A), ns(0x8FB37E), ns(0x7A9BC4), ns(0xA88BC4)]
    )

    /// Bonsai Light — #575757 ink on soft stone paper (never pure black ink).
    static let bonsaiLight = ThemeFlavor(
        isDark: false,
        text: ns(0x575757), subtext1: ns(0x6B6B69), subtext0: ns(0x757572),
        overlay2: ns(0x8F8F8B), overlay1: ns(0x9B9B96), overlay0: ns(0xACACA6),
        surface2: ns(0xC4C3BC), surface1: ns(0xD3D2CA), surface0: ns(0xDEDDD5),
        base: ns(0xF5F4EF), mantle: ns(0xFAF9F5), crust: ns(0xEBEAE4),
        accent: ns(0x5A7FA8),
        info: ns(0x5A7FA8),
        tints: [ns(0xC25A50), ns(0xC27E4A), ns(0xAF8B34), ns(0x6E9B5C), ns(0x5A7FA8), ns(0x8A6BAA)]
    )

    /// Catppuccin Mocha — accent = mauve, info = blue.
    static let mocha = ThemeFlavor(
        isDark: true,
        text: ns(0xCDD6F4), subtext1: ns(0xBAC2DE), subtext0: ns(0xA6ADC8),
        overlay2: ns(0x9399B2), overlay1: ns(0x7F849C), overlay0: ns(0x6C7086),
        surface2: ns(0x585B70), surface1: ns(0x45475A), surface0: ns(0x313244),
        base: ns(0x1E1E2E), mantle: ns(0x181825), crust: ns(0x11111B),
        accent: ns(0xCBA6F7),   // mauve
        info: ns(0x89B4FA),     // blue
        tints: [ns(0xF38BA8), ns(0xFAB387), ns(0xF9E2AF), ns(0xA6E3A1), ns(0x89B4FA), ns(0xCBA6F7)]
    )

    /// Catppuccin Latte — accent = mauve, info = blue.
    static let latte = ThemeFlavor(
        isDark: false,
        text: ns(0x4C4F69), subtext1: ns(0x5C5F77), subtext0: ns(0x6C6F85),
        overlay2: ns(0x7C7F93), overlay1: ns(0x8C8FA1), overlay0: ns(0x9CA0B0),
        surface2: ns(0xACB0BE), surface1: ns(0xBCC0CC), surface0: ns(0xCCD0DA),
        base: ns(0xEFF1F5), mantle: ns(0xE6E9EF), crust: ns(0xDCE0E8),
        accent: ns(0x8839EF),   // mauve
        info: ns(0x1E66F5),     // blue
        tints: [ns(0xD20F39), ns(0xFE640B), ns(0xDF8E1D), ns(0x40A02B), ns(0x1E66F5), ns(0x8839EF)]
    )
}

// MARK: - Active flavor holder (survives view rebuilds; lives outside the tree)

/// The single source of truth for the active flavor. Persisted, and mutated by
/// the flavor switcher. Theme switching rebuilds the whole SwiftUI tree, so the
/// resolved palette is captured at render from `ActiveTheme.current`.
@MainActor
enum ActiveTheme {
    static let storageKey = "billiejean.flavor"

    private(set) static var selected: Flavor = {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let f = Flavor(rawValue: raw) {
            return f
        }
        return .bonsaiDark
    }()

    static var current: ThemeFlavor { selected.flavor }

    /// Persist + update the active flavor. Callers must rebuild the window content.
    static func set(_ flavor: Flavor) {
        selected = flavor
        UserDefaults.standard.set(flavor.rawValue, forKey: storageKey)
    }
}

// MARK: - Layer 2: Theme.Palette (semantic roles resolved at render)

extension Theme {
    /// Semantic color roles. Views consume ONLY these — never a flavor slot,
    /// hex, or `.white`/`.black`. Each is a plain lookup against the active flavor.
    @MainActor
    enum Palette {
        private static var f: ThemeFlavor { ActiveTheme.current }
        private static func c(_ ns: NSColor) -> Color { Color(nsColor: ns) }
        private static func c(_ ns: NSColor, _ a: Double) -> Color {
            Color(nsColor: ns.withAlphaComponent(a))
        }

        static var isDark: Bool { f.isDark }

        // Ink
        static var accent: Color { c(f.accent) }
        static var info: Color { c(f.info) }
        static var body: Color { c(f.text) }
        static var title: Color { c(f.overlay1) }
        static var placeholder: Color { c(f.overlay1) }
        static var count: Color { c(f.overlay0) }
        static var menuDesc: Color { c(f.subtext0) }

        // Fills / washes
        static var accentFill: Color { c(f.accent, 0.20) }
        static var selectedRowFill: Color { c(f.accent, 0.24) }
        static var rowFill: Color { c(f.surface0, 0.45) }
        static var panelHairline: Color { c(f.overlay0, 0.35) }
        static var popupScrim: Color { c(f.base, 0.60) }
        static var raisedTint: Color { c(f.base, 0.45) }
        static var raisedRim: Color { c(f.overlay0, 0.25) }
        static var windowCanvas: Color { c(f.base) }

        // Chrome
        static var chromeGlyph: Color { c(f.subtext1) }
        static var chromeGlyphHover: Color { c(f.text) }
        static var chromeGlyphDim: Color { c(f.overlay0) }
        static var chromeBadge: Color { c(f.overlay1) }
        static var chromeText: Color { c(f.subtext1) }
        static var hoverWash: Color { c(f.surface1, 0.55) }
        static var chromeDivider: Color { c(f.surface2, 0.80) }
        static var separator: Color { c(f.surface2, 0.60) }
        static var keycapFill: Color { c(f.surface0, 0.70) }
        static var segmentedFill: Color { c(f.surface0, 0.55) }
        static var buttonHover: Color { c(f.surface1, 0.80) }

        // Content
        static var labelChipFill: Color { c(f.isDark ? f.surface0 : f.mantle) }

        // Physical objects (3D deck faceplate): raised-button, knob, VU, lenses.
        // All computed from the active flavor so light themes get light materials.

        // Raised transport button: radial gradient body + edge light + sink shadow.
        static var buttonHighlight: Color { c(f.surface2) }          // top-left catch light
        static var buttonBody: Color { c(f.surface0) }               // body
        static var buttonBodyPressed: Color { c(f.surface0.darkened(by: 0.08)) }
        static var buttonEdgeLight: Color { c(f.text, 0.09) }        // 1pt top rim (8–10%)
        static var buttonInnerShadow: Color { .black.opacity(f.isDark ? 0.55 : 0.22) }

        // Physical knob (glossy-black recipe, palette-driven so light = light material).
        static var knobHighlight: Color { c(f.surface2) }            // radial catch light
        static var knobBody: Color { c(f.isDark ? f.crust : f.surface0) }  // deep body
        static var knobRim: Color { c(f.overlay0) }                  // 1pt inset rim
        static var knobIndicator: Color { c(f.isDark ? f.text : f.base) }  // contrasting line

        // Indicator lenses.
        static var lensRim: Color { c(f.crust) }
        static var lensOff: Color { c(f.surface0) }

        // VU face detail.
        static var vuGlassSheen: Color { c(f.text, 0.04) }
        static var vuInnerShadow: Color { .black.opacity(f.isDark ? 0.40 : 0.15) }

        // Solid time-chip surface for the tonearm seek (rule 10 — never translucent).
        static var chipFill: Color { c(f.isDark ? f.surface0 : f.mantle) }

        // Braun-inspired skeuomorphic materials (the instrument, not chrome).
        // Light flavors read as warm cream hardware; dark flavors as charcoal.
        static var faceTop: Color { f.isDark ? c(f.surface1) : c(f.mantle) }
        static var faceBottom: Color {
            f.isDark ? c(f.surface0).darkened(by: 0.30) : c(f.crust)
        }
        static var faceEdgeLight: Color { .white.opacity(f.isDark ? 0.08 : 0.75) }
        static var faceWell: Color {
            f.isDark ? c(f.base).mixed(with: c(f.surface0), by: 0.4) : c(f.surface1)
        }
        static var ctrlLight: Color { f.isDark ? c(f.surface2) : c(f.mantle) }
        static var ctrlDark: Color {
            f.isDark ? c(f.surface0).darkened(by: 0.18) : c(f.surface2)
        }
        static var bezelDark: Color { .black.opacity(f.isDark ? 0.55 : 0.30) }
        static var insetHi: Color { .white.opacity(f.isDark ? 0.22 : 0.90) }
        static var insetLo: Color { .black.opacity(f.isDark ? 0.60 : 0.30) }
        static var printedInk: Color { c(f.subtext0) }
        static var leverTop: Color { f.isDark ? c(f.surface2) : c(f.overlay1) }
        static var leverBottom: Color { f.isDark ? c(f.crust) : c(f.overlay2).darkened(by: 0.35) }
        /// Hardware colors — the ONE orange and ONE green, always tint slots.
        static var hwOrange: Color { tint(1) }
        static var hwGreen: Color { tint(3) }

        // A tint slot by index (user colors are slot indexes, resolved at draw).
        static func tint(_ index: Int) -> Color {
            let tints = f.tints
            guard !tints.isEmpty else { return accent }
            return c(tints[((index % tints.count) + tints.count) % tints.count])
        }
    }

    /// Shadow tokens (color = black at alpha, chosen per light/dark).
    @MainActor
    enum Shadow {
        struct Spec { let color: Color; let radius: CGFloat; let y: CGFloat }
        private static var dark: Bool { ActiveTheme.current.isDark }

        static var panel: Spec { Spec(color: .black.opacity(dark ? 0.45 : 0.20), radius: 36, y: 18) }
        static var bar: Spec { Spec(color: .black.opacity(dark ? 0.36 : 0.18), radius: 18, y: 8) }
        static var menu: Spec { Spec(color: .black.opacity(dark ? 0.25 : 0.16), radius: 16, y: 8) }
    }
}

// MARK: - WindowChrome (the one control grid)

/// Every floating control is built from these constants. No inline sizes,
/// paddings, fonts, or radii in any chrome view.
enum WindowChrome {
    static let controlHeight: CGFloat = 34
    static let padH: CGFloat = 6
    static let padV: CGFloat = 5
    static let radius: CGFloat = 14
    static let edgeInset: CGFloat = 16
    static let trafficLightInset: CGFloat = 132
    static let iconSize: CGFloat = 17
    static let iconFont: Font = .system(size: 17, weight: .medium)
    static let labelFont: Font = .system(size: 13, weight: .medium)
    static let labelPadH: CGFloat = 10
    static let itemSpacing: CGFloat = 4

    // Derived
    static let pillHeight: CGFloat = controlHeight + padV * 2          // 44
    static let rowCenterY: CGFloat = edgeInset + pillHeight / 2        // 38
    static let panelBottomClearance: CGFloat = edgeInset + controlHeight + padV * 2 + 8  // 68

    // Additional radii (§6)
    static let panelRadius: CGFloat = 22
    static let actionBarRadius: CGFloat = 12
    static let rowRadius: CGFloat = 9
    static let inBarHoverRadius: CGFloat = 8
    static let listRowRadius: CGFloat = 7

    // Corner badge font
    static let badgeFont: Font = .system(size: 8, weight: .bold)

    // Secondary text scales (grid subtitles, knob captions, indicator labels)
    static let sublabelFont: Font = .system(size: 11, weight: .regular)
    static let captionFont: Font = .system(size: 10, weight: .regular)
    static let microFont: Font = .system(size: 8, weight: .medium)

    /// The turntable's hero play/pause control — the one sanctioned larger control.
    static let deckControlHeight: CGFloat = 44
}

// MARK: - Signature motion

enum ChromeMotion {
    /// One signature spring for chrome appearance/layout.
    static let spring: Animation = .spring(response: 0.28, dampingFraction: 0.82)
    static let hover: Animation = .easeOut(duration: 0.12)
    static let expand: Animation = .easeOut(duration: 0.15)
    static let dismiss: Animation = .easeOut(duration: 0.16)
}
