import SwiftUI
import AppKit

// MARK: - Icon button (the workhorse)

/// 34×34 plain button; SF Symbol at iconFont; Circle hover wash; no fill for
/// active — the accent-tinted glyph IS the active signal. `diameter` is grid-
/// token-derived; the turntable's hero play/pause passes `deckControlHeight`.
@available(macOS 14.2, *)
struct ChromeIconButton: View {
    let symbol: String
    let help: String
    var active = false
    var disabled = false
    var diameter: CGFloat = WindowChrome.controlHeight
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            Image(systemName: symbol)
                .font(WindowChrome.iconFont)
                .foregroundStyle(foreground)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(hovering && !disabled ? Theme.Palette.hoverWash : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
        .animation(ChromeMotion.hover, value: hovering)
    }

    private var foreground: AnyShapeStyle {
        if disabled { return AnyShapeStyle(Theme.Palette.chromeGlyphDim) }
        if active { return AnyShapeStyle(Theme.Palette.accent) }
        return AnyShapeStyle(hovering ? Theme.Palette.chromeGlyphHover : Theme.Palette.chromeGlyph)
    }
}

/// A 34pt-tall text label pill button (identity / playlist name inside the pill).
@available(macOS 14.2, *)
struct ChromeTextLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(WindowChrome.labelFont)
            .foregroundStyle(Theme.Palette.body)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, WindowChrome.labelPadH)
            .frame(height: WindowChrome.controlHeight)
    }
}

/// 1pt divider inside the command bar.
@available(macOS 14.2, *)
struct BarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.chromeDivider)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
    }
}

// MARK: - Seek slider (thin, accent fill, drag-to-seek)

/// A thin seek slider matching chrome grammar. Fraction drives the accent fill;
/// dragging reports a new time to `onSeek`. ~160pt wide.
@available(macOS 14.2, *)
struct SeekSlider: View {
    let position: Double?
    let duration: Double?
    let onSeek: (Double) -> Void

    var width: CGFloat = 160
    @State private var dragFraction: Double?

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard let position, let duration, duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.chromeDivider).frame(height: 3)
                Capsule().fill(Theme.Palette.accent)
                    .frame(width: w * fraction, height: 3)
                Circle()
                    .fill(Theme.Palette.accent)
                    .frame(width: 8, height: 8)
                    .offset(x: w * fraction - 4)
                    .opacity(dragFraction == nil ? 0 : 1)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragFraction = min(1, max(0, g.location.x / w))
                    }
                    .onEnded { _ in
                        if let f = dragFraction, let duration {
                            onSeek(f * duration)
                        }
                        dragFraction = nil
                    }
            )
            .animation(dragFraction == nil ? .easeInOut(duration: 0.4) : nil, value: fraction)
        }
        .frame(width: width, height: WindowChrome.controlHeight)
    }
}

// MARK: - Glass menu scaffolding

/// One glass menu surface — a small floating card of rows.
@available(macOS 14.2, *)
struct GlassMenu<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
        }
        .padding(6)
        .frame(width: 220)
        .composerPopupSurface(radius: WindowChrome.radius)
        .shadow(color: Theme.Shadow.menu.color, radius: Theme.Shadow.menu.radius, y: Theme.Shadow.menu.y)
    }
}

/// A menu row: title + optional checkmark; hover wash.
@available(macOS 14.2, *)
struct GlassMenuRow: View {
    let title: String
    var checked = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            HStack(spacing: 8) {
                Text(title)
                    .font(WindowChrome.labelFont)
                    .foregroundStyle(Theme.Palette.body)
                Spacer(minLength: 8)
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WindowChrome.listRowRadius, style: .continuous)
                    .fill(hovering ? Theme.Palette.hoverWash : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ChromeMotion.hover, value: hovering)
    }
}

/// A menu row hosting a toggle (settings).
@available(macOS 14.2, *)
struct GlassMenuToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(WindowChrome.labelFont)
                .foregroundStyle(Theme.Palette.body)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.Palette.accent)
                .scaleEffect(0.72)
                .frame(width: 34)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }
}

// MARK: - Toast

@available(macOS 14.2, *)
struct ToastView: View {
    let symbol: String
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Palette.accent)
            Text(message)
                .font(WindowChrome.labelFont)
                .foregroundStyle(Theme.Palette.body)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .composerPopupSurface(radius: WindowChrome.radius)
        .shadow(color: Theme.Shadow.menu.color, radius: Theme.Shadow.menu.radius, y: Theme.Shadow.menu.y)
    }
}
