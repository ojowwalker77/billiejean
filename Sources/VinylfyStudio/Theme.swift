import SwiftUI

/// Card geometry shared by every skin.
enum Theme {
    static let cardWidth: CGFloat = 300
    static let cardHeight: CGFloat = 440
    static let cardCornerRadius: CGFloat = 28

    /// Fallback record color when no artwork.
    static let amberRecord = Color(hex: 0xB0642F)
}

/// The selectable widget skins.
enum SkinKind: String, CaseIterable {
    case paper
    case wood
    case graphite

    var displayName: String {
        switch self {
        case .paper: return "Paper"
        case .wood: return "Wood"
        case .graphite: return "Graphite"
        }
    }
}

/// A complete set of surface/ink tokens for one skin. The record itself stays
/// artwork-driven; the skin dresses the card, text, and controls around it.
struct Skin: Equatable {
    let kind: SkinKind

    // Card surface (vertical luminance gradient, lighter at top).
    let cardTop: Color
    let cardMid: Color
    let cardBottom: Color
    let cardBorder: Color
    /// Draw the wood-grain overlay on the card surface.
    let grain: Bool

    // Ink / text
    let ink: Color
    let secondary: Color
    let hairline: Color

    // Chrome (small) knobs + beads
    let chromeTop: Color
    let chromeBottom: Color
    let chromeBorder: Color

    // Big main knob
    let knobHighlight: Color
    let knobBody: Color
    let knobRim: Color
    /// Indicator line on the main knob (must contrast the knob body on every skin).
    let knobIndicator: Color

    let stoppedDot: Color

    static func skin(for kind: SkinKind) -> Skin {
        switch kind {
        case .paper: return .paper
        case .wood: return .wood
        case .graphite: return .graphite
        }
    }

    /// The original look — a physical object photographed on warm paper.
    static let paper = Skin(
        kind: .paper,
        cardTop: Color(hex: 0xFAF8F5),
        cardMid: Color(hex: 0xF5F3F0),
        cardBottom: Color(hex: 0xEFECE7),
        cardBorder: Color(hex: 0xDCD7D0).opacity(0.6),
        grain: false,
        ink: Color(hex: 0x2A2622),
        secondary: Color(hex: 0x8D857B),
        hairline: Color(hex: 0xDCD7D0),
        chromeTop: .white,
        chromeBottom: Color(hex: 0xE4E0DA),
        chromeBorder: Color(hex: 0xC9C3BA),
        knobHighlight: Color(hex: 0x3A3430),
        knobBody: Color(hex: 0x16120F),
        knobRim: Color(hex: 0x4A443E),
        knobIndicator: Color(hex: 0xF5F3F0),
        stoppedDot: Color(hex: 0xB9B2A8)
    )

    /// Warm brownish wood — cream ink on stained planks.
    static let wood = Skin(
        kind: .wood,
        cardTop: Color(hex: 0x9E6B3C),
        cardMid: Color(hex: 0x8C5A2F),
        cardBottom: Color(hex: 0x774A24),
        cardBorder: Color(hex: 0x5E3A1A).opacity(0.8),
        grain: true,
        ink: Color(hex: 0xF3E7D3),
        secondary: Color(hex: 0xD8BC96),
        hairline: Color(hex: 0x6B4520),
        chromeTop: Color(hex: 0xFDF6EA),
        chromeBottom: Color(hex: 0xE2D3BC),
        chromeBorder: Color(hex: 0xB89A73),
        knobHighlight: Color(hex: 0x40362C),
        knobBody: Color(hex: 0x151009),
        knobRim: Color(hex: 0x54463A),
        knobIndicator: Color(hex: 0xF3E7D3),
        stoppedDot: Color(hex: 0xC9AA82)
    )

    /// Dark graphite — silver controls on near-black slate.
    static let graphite = Skin(
        kind: .graphite,
        cardTop: Color(hex: 0x2E2B28),
        cardMid: Color(hex: 0x252320),
        cardBottom: Color(hex: 0x1D1B19),
        cardBorder: Color(hex: 0x3B3833).opacity(0.9),
        grain: false,
        ink: Color(hex: 0xE9E5DF),
        secondary: Color(hex: 0x8F8A82),
        hairline: Color(hex: 0x3B3833),
        chromeTop: Color(hex: 0xE8E6E2),
        chromeBottom: Color(hex: 0xB9B5AF),
        chromeBorder: Color(hex: 0x8E8A84),
        knobHighlight: Color(hex: 0x4A4540),
        knobBody: Color(hex: 0x0F0D0B),
        knobRim: Color(hex: 0x565049),
        knobIndicator: Color(hex: 0xE9E5DF),
        stoppedDot: Color(hex: 0x6E6961)
    )
}

extension Color {
    /// Build a Color from a 24-bit RGB hex literal, e.g. `Color(hex: 0xE8A34A)`.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    /// Blend toward another color by `t` (0 = self, 1 = other) in sRGB.
    func mixed(with other: Color, by t: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let clamped = min(1, max(0, t))
        return Color(
            .sRGB,
            red: Double(a.redComponent) * (1 - clamped) + Double(b.redComponent) * clamped,
            green: Double(a.greenComponent) * (1 - clamped) + Double(b.greenComponent) * clamped,
            blue: Double(a.blueComponent) * (1 - clamped) + Double(b.blueComponent) * clamped
        )
    }

    /// Darken toward black by `amount` (0…1).
    func darkened(by amount: Double) -> Color {
        mixed(with: .black, by: amount)
    }

    /// Fully desaturate to its luminance-equivalent gray.
    var desaturated: Color {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let l = 0.299 * Double(c.redComponent) + 0.587 * Double(c.greenComponent) + 0.114 * Double(c.blueComponent)
        return Color(.sRGB, red: l, green: l, blue: l)
    }
}
