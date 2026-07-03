import SwiftUI

/// Design tokens for the Vinylfy widget — a physical object photographed on paper.
enum Theme {
    // Paper card
    static let paper       = Color(hex: 0xF5F3F0) // very light warm paper
    static let paperTop    = Color(hex: 0xFAF8F5) // lighter top of the luminance gradient
    static let paperBottom = Color(hex: 0xEFECE7) // slightly deeper bottom

    // Ink / text
    static let ink       = Color(hex: 0x2A2622)
    static let secondary = Color(hex: 0x8D857B)
    static let hairline  = Color(hex: 0xDCD7D0)

    // Chrome knob
    static let chromeTop    = Color.white
    static let chromeBottom = Color(hex: 0xE4E0DA)
    static let chromeBorder = Color(hex: 0xC9C3BA)

    // Black main knob
    static let knobHighlight = Color(hex: 0x3A3430)
    static let knobBody      = Color(hex: 0x16120F)
    static let knobRim       = Color(hex: 0x4A443E)

    // Fallback record color when no artwork.
    static let amberRecord = Color(hex: 0xB0642F)

    // Status
    static let stoppedDot = Color(hex: 0xB9B2A8)

    // Card geometry
    static let cardWidth: CGFloat = 300
    static let cardHeight: CGFloat = 440
    static let cardCornerRadius: CGFloat = 28
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
