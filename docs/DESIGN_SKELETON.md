# The BonsAI window skeleton — a portable design system

> Provided by the owner as the definitive reference for how billiejean's main-window UI
> must look and be structured. Follow it exactly — metrics, colors, layer order, and rules.

This document describes the visual and structural skeleton of BonsAI (a macOS SwiftUI/AppKit
app) precisely enough for another Claude to replicate it in a brand-new app, without access to
this codebase. It is not a style guide of adjectives — it is exact metrics, exact colors, exact
layer order, and the failure modes that shaped each rule.

**The look in one sentence:** a single standard macOS window whose content is a solid, themed
canvas filling every pixel, with *all* chrome — every button, bar, and panel — floating over
that canvas as Liquid Glass pills that share one control grid, one glass recipe, and one
semantic palette.

---

## 1. The architecture: one window, floating chrome

There is exactly **one** window. No auxiliary panels, no sibling NSWindows, no sheets for
primary UI. Everything that isn't canvas content is an overlay *inside* the window:

```
NSPanel (titled, resizable, fullSizeContentView, transparent titlebar)
└── SwiftUI root (GeometryReader → ZStack, .topLeading)
    ├── Canvas backdrop        (solid themed surface over a behind-window blur)
    ├── Canvas content         (the app's actual workspace — pans/zooms under the chrome)
    ├── Content overlays       (contextual toolbars anchored to selected items)
    ├── Top-left identity pill (after the repositioned traffic lights)   zIndex 60
    ├── Top-right actions pill                                            (default z)
    ├── Bottom-center command bar (THE toolbar — everything hands-on)     (default z)
    ├── Docked side panels     (settings / chat — glass cards, not windows) zIndex 40
    ├── Modal-ish overlays     (command palette, focus sheet)             higher z
    └── Toast                  (bottom-center, above the bar)
```

Spatial grammar — this is the part that makes it feel composed rather than scattered:

- **Top-left = identity.** What am I looking at (document/board name). It sits on the same
  centerline as the traffic lights, to their right, so the top-left reads as one row.
- **Top-right = presence.** Ambient toggles (AI/chat). One small pill, usually one icon.
- **Bottom-center = hands.** ONE command bar holding every frequently-touched control:
  zoom cluster · the tool set · color · utilities · settings. tldraw-style. Never split
  this into multiple bottom pills — a single strong grouping is the point.
- **Right edge = panels.** Settings and chat dock as floating glass cards on the right,
  top-inset 10% of window height, stopping *above* the bottom bar (never covering its end).
- The top stays calm; the bottom is dense. Nothing floats mid-canvas except content.

## 2. The window recipe (AppKit)

An `NSPanel` subclass configured to behave as a standard document window:

```swift
final class AppWindow: NSPanel {
  override var canBecomeKey: Bool { true }   // MANDATORY — panels default false in some
  override var canBecomeMain: Bool { true }  // configs; without it no insertion point.

  init(contentRect: NSRect) {
    super.init(contentRect: contentRect,
               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
               backing: .buffered, defer: false)
    isFloatingPanel = false
    level = .normal                       // a Dock-app window, not always-on-top
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovable = true
    isMovableByWindowBackground = false   // the canvas owns background drag (panning)
    collectionBehavior = [.fullScreenPrimary]
    isOpaque = false                      // the canvas paints its own surface;
    backgroundColor = .clear              // non-opaque so behind-window blur can sample
    hasShadow = true
    isReleasedWhenClosed = false
    animationBehavior = .none
    appearance = /* NSAppearance for the selected theme (dark by default) */
  }
}
```

Sizing: `minSize` 640×460; first-launch frame `min(1180, visibleWidth * 0.72)` ×
`min(820, visibleHeight * 0.84)` centered; then `setFrameAutosaveName(...)` and never
reframe on summon — the window keeps whatever frame the user left it at.

Host SwiftUI with `NSHostingView`, `sizingOptions = []` (never let SwiftUI infer the window
size), pinned to all four edges of a container view whose `mouseDownCanMoveWindow` is
`false` — otherwise click-drags on the canvas move the window instead of panning.

### Traffic lights on the control row

AppKit puts the close/min/zoom buttons in the top-left corner; the floating pills sit lower.
That mismatch makes the top-left read as two unrelated rows. Fix: reposition the buttons onto
the **same centerline** as the floating control row:

```swift
func layoutWindowChromeButtons() {
  guard !styleMask.contains(.fullScreen) else { return }
  guard let container = standardWindowButton(.closeButton)?.superview else { return }
  // Centerline of a floating pill: edgeInset + (controlHeight + padV*2) / 2
  let rowCenterY = WindowChrome.edgeInset + (WindowChrome.controlHeight + WindowChrome.padV * 2) / 2
  var x = WindowChrome.edgeInset
  for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
    guard let button = standardWindowButton(type) else { continue }
    let y = container.isFlipped
      ? rowCenterY - button.frame.height / 2
      : container.frame.height - rowCenterY - button.frame.height / 2
    button.setFrameOrigin(NSPoint(x: x, y: y))
    x += button.frame.width + 6
  }
}
```

**AppKit resets these frames** on resize, move, and key-state changes. The window's delegate
must re-call `layoutWindowChromeButtons()` from `windowDidResize`, `windowDidMove`,
`windowDidBecomeKey`, and `windowDidResignKey`, and after every content rebuild. Omitting any
one of these hooks produces intermittently mispositioned traffic lights.

## 3. `WindowChrome` — the one control grid

Every floating control in the app is built from these constants. **No inline sizes, paddings,
fonts, or corner radii in any chrome view** — that is how sibling pills drift into four
bespoke shapes.

| Token | Value | Meaning |
|---|---|---|
| `controlHeight` | **34** | Every control is a 34pt square (or 34pt-tall label) |
| `padH` / `padV` | **6 / 5** | Inner padding of every pill around its control row |
| `radius` | **14** | Corner radius of every pill/bar (continuous corners) |
| `edgeInset` | **16** | Uniform distance of every pill from the window edges |
| `trafficLightInset` | **132** | Leading offset of the top-left pill — clears the traffic lights' *practical hit area*, which is wider than the visible dots |
| `iconSize` / `iconFont` | **17**, `.system(size: 17, weight: .medium)` | Every chrome glyph — one size, one weight |
| `labelFont` | `.system(size: 13, weight: .medium)` | Every chrome text label (name, zoom %, chips) |
| `labelPadH` | **10** | Inner horizontal padding for text-bearing controls (icons are square and need none) |
| `itemSpacing` | **4** | Spacing between sibling controls inside one pill/bar |

Derived numbers you will need:
- Pill total height = 34 + 5×2 = **44pt**.
- Control-row centerline (for traffic lights) = 16 + 44/2 = **38pt** from the top.
- A docked panel's bottom clearance above the command bar = `edgeInset + controlHeight
  + padV*2 + 8` = **68pt**.

### The one pill wrapper

```swift
extension View {
  /// THE one wrapper for every floating chrome pill and bar: identical padding, radius, glass.
  /// Views never add their own surface padding — wrap the control row in this and it is, by
  /// construction, the same size as every other pill.
  func chromePill() -> some View {
    self
      .padding(.horizontal, WindowChrome.padH)
      .padding(.vertical, WindowChrome.padV)
      .composerPopupSurface(radius: WindowChrome.radius)
  }
}
```

Never hand-assemble a pill with raw `.padding(...)` + a glass background. Every pill is
`content row → .chromePill() → .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:)
→ .padding(edgeInset)`, alignment doing the anchoring (`.topLeading`, `.topTrailing`,
`.bottom`).

## 4. The glass recipe — one surface for everything

There is exactly **one** raised-surface material, used by every pill, bar, menu, and panel:

```swift
extension View {
  @ViewBuilder
  func floatingGlass<S: Shape>(_ shape: S) -> some View {
    if #available(macOS 26.0, *) {
      self
        .clipShape(shape)
        .background(Theme.Palette.raisedTint, in: shape)  // flavor base @ 45% under the glass
        .glassEffect(.regular, in: shape)                 // real Liquid Glass
    } else {
      self
        .background {
          ZStack {
            VisualEffectBackground(material: .menu, blending: .withinWindow, state: .active)
            Theme.Palette.popupScrim                      // flavor base @ 60%
          }
        }
        .clipShape(shape)
        .shadow(color: Theme.Shadow.menu.color, radius: 16, y: 8)
    }
  }

  func composerPopupSurface(radius: CGFloat = 14) -> some View {   // pills, bars, menus
    floatingGlass(RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
  func dockPanelSurface(radius: CGFloat = 22) -> some View {       // docked side panels
    floatingGlass(RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
}
```

Key decisions baked into this recipe:
- The tint under the glass is **the flavor's own `base` color at 0.45 alpha**
  (`raisedTint`), so pills read as *raised canvas material* in every theme — not as gray
  chips. This is the uniform legibility layer; without it glass over busy content is
  unreadable.
- **Deliberately uniform — no internal gradient/sheen.** A manual sheen shifts shade over a
  busy or light backdrop; flat tint doesn't.
- **No custom frosts, no white-fill "frosted" variants.** Tried; rejected as generic gray.
- Always `style: .continuous` corners.

### The canvas backdrop

The canvas is **solid by default**, painted over a behind-window blur so a user-facing
transparency slider can recede it toward desktop glass:

```swift
struct PanelBackground: View {
  @AppStorage("canvasTransparency") private var transparency = 0.0   // default 0 = solid
  var body: some View {
    let glass = /* clamped 0…max, normalized 0…1 */
    ZStack {
      VisualEffectBackground(material: .hudWindow, blending: .behindWindow, state: .active)
      Theme.Palette.windowCanvas.opacity(1.0 - 0.65 * glass)  // never fully clear
    }
    .ignoresSafeArea()
  }
}
```

At 0 the surface is indistinguishable from solid. The window must stay non-opaque with a
clear backing for the blur to sample — don't "optimize" it back to opaque.

## 5. The color system — flavors and semantic tokens

Two layers, strictly separated. **Views never see a hex or a `Color.white`/`Color.black`;
every hard-coded literal has broken one theme.**

### Layer 1: `ThemeFlavor` — a theme as pure data

Slot semantics follow Catppuccin's model: `text` > `subtext1/0` (secondary ink) >
`overlay2/1/0` (dim ink, hairlines) > `surface2/1/0` (fills) > `base`/`mantle`/`crust`
(backgrounds). Plus `isDark`, one `accent`, one `info`, and six `tints` in a FIXED semantic
order (red, orange, yellow, green, blue, purple).

```swift
struct ThemeFlavor {
  let isDark: Bool
  let text, subtext1, subtext0: NSColor
  let overlay2, overlay1, overlay0: NSColor
  let surface2, surface1, surface0: NSColor
  let base, mantle, crust: NSColor
  let accent: NSColor       // THE one accent: selection, active tool, primary action
  let info: NSColor         // informational tint (link-ish chips)
  let tints: [NSColor]      // user-pickable element colors, stored as slot INDEXES
}
```

Adding a theme is a data change — a new `ThemeFlavor` + one enum case, never a view change.

The four shipped flavors (copy these exactly for the same look):

**Bonsai Dark** — stone ink on pure black; accent = `NSColor.controlAccentColor` (system):
`text #E3E2DD · subtext1 #A5A4A0 · subtext0 #9B9A96 · overlay2 #807F7C · overlay1 #585856 ·
overlay0 #403F3E · surface2 #2A2A28 · surface1 #1F1F1E · surface0 #161615 · base #000000 ·
mantle #2B2B2B · crust #000000 · tints [#D97A74 #D99A6C #D4B96A #8FB37E #7A9BC4 #A88BC4]`

**Bonsai Light** — #575757 ink on soft stone paper (never pure black ink on light):
`text #575757 · subtext1 #6B6B69 · subtext0 #757572 · overlay2 #8F8F8B · overlay1 #9B9B96 ·
overlay0 #ACACA6 · surface2 #C4C3BC · surface1 #D3D2CA · surface0 #DEDDD5 · base #F5F4EF ·
mantle #FAF9F5 · crust #EBEAE4 · tints [#C25A50 #C27E4A #AF8B34 #6E9B5C #5A7FA8 #8A6BAA]`

**Catppuccin Mocha / Latte** — the published palettes (catppuccin.com), accent = mauve,
info = blue, tints = [red, peach, yellow, green, blue, mauve].

### Layer 2: `Theme.Palette` — semantic roles resolved at render

Views consume ONLY these. Each is a plain lookup against the active flavor (with alpha):

| Token | Recipe | Used for |
|---|---|---|
| `accent` | flavor.accent | THE accent — active tool glyph, selection, send |
| `body` | text | primary ink |
| `title` / `placeholder` | overlay1 | dim headings, placeholder text |
| `count` | overlay0 | faintest ink (counters) |
| `menuDesc` | subtext0 | secondary rows in menus |
| `accentFill` | accent @ 0.20 | soft accent wash |
| `selectedRowFill` | accent @ 0.24 | selected list row |
| `rowFill` | surface0 @ 0.45 | neutral row/chip fill |
| `panelHairline` | overlay0 @ 0.35 | hairline strokes |
| `popupScrim` | base @ 0.60 | fallback-glass scrim |
| `raisedTint` | base @ 0.45 | the under-glass tint (see §4) |
| `raisedRim` | overlay0 @ 0.25 | optional pill rim |
| `windowCanvas` | base | the canvas itself |
| `chromeGlyph` | subtext1 | resting chrome icon |
| `chromeGlyphHover` | text | hovered chrome icon |
| `chromeGlyphDim` | overlay0 | disabled chrome icon |
| `chromeBadge` | overlay1 | tiny corner badges (shortcut numbers) |
| `chromeText` | subtext1 | chrome labels (zoom %) |
| `hoverWash` | surface1 @ 0.55 | THE hover background (see §7) |
| `chromeDivider` | surface2 @ 0.80 | 1pt dividers inside the bar |
| `separator` | surface2 @ 0.60 | menu dividers |
| `keycapFill` | surface0 @ 0.70 | keycap chips |
| `segmentedFill` | surface0 @ 0.55 | segmented control track |
| `buttonHover` | surface1 @ 0.80 | settings-row hover |

Content-drawing tokens, if the app draws user elements: `inkStroke` text @ 0.92,
`elementStroke` text @ 0.85, `elementFill` = dark ? surface0 @ 0.55 : text @ **0.001**
(near-zero, not `.clear`, so interiors still hit-test), `elementShadow` = dark ? crust @
0.55 : `.clear` (ink on paper casts no shadow), `labelChipFill` = **solid** surface0 (dark) /
mantle (light) — translucent chip fills let the chip's own shadow bleed through ("gray
smear").

User-pickable colors are stored as **tint slot indexes**, never resolved colors — an element
tinted "3" is green in every theme and re-resolves on switch.

### Theme switching

Palette tokens are plain lookups captured at render, so switching themes **rebuilds the whole
SwiftUI tree**: set the window's `NSAppearance`, re-install the root content view, re-layout
the traffic lights. Anything that must survive (documents, a chat conversation) lives in
stores/singletons outside the view tree. Also apply the theme's appearance to the window
itself so system controls resolve to the right appearance class.

## 6. Remaining tokens

**Radii** — panel 22 (docked panels) · menu/pill 14 · actionBar 12 · row 9 · in-bar control
hover 8 · list rows inside pills 7.

**Shadows** (color = black at alpha, light/dark):
- panel: alpha 0.20/0.45, radius 36, y 18 — docked side panels only
- bar: alpha 0.18/0.36, radius 18, y 8
- menu: alpha 0.16/0.25, radius 16, y 8 — the fallback-glass shadow

**Motion** — one signature spring for chrome appearance/layout:
`Animation.spring(response: 0.28, dampingFraction: 0.82)`. Hover states:
`.easeOut(duration: 0.12)`. Small expand/collapse (pickers): `.easeOut(0.14–0.16)`.
Dismiss: 0.16s. Panels enter with `.move(edge: .trailing).combined(with: .opacity)`; toasts
with `.move(edge: .bottom).combined(with: .opacity)`.

**Typography** — chrome uses only `WindowChrome.iconFont` (17 medium) and
`WindowChrome.labelFont` (13 medium; `.monospacedDigit()` for live numbers like zoom %).
Corner badges: `.system(size: 8, weight: .bold)`. Content text: body with +3pt line
spacing; menus use `.body` names over `.caption` descriptions.

## 7. Component recipes

### Icon button (the workhorse)

34×34 plain button; SF Symbol at `iconFont`; **Circle** hover wash; no fill for active state
— the accent-tinted glyph IS the active signal:

```swift
struct ChromeIconButton: View {
  let symbol: String; let help: String
  var active = false; var disabled = false
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: { Haptics.tap(); action() }) {
      Image(systemName: symbol)
        .font(WindowChrome.iconFont)
        .foregroundStyle(foreground)
        .frame(width: WindowChrome.controlHeight, height: WindowChrome.controlHeight)
        .background(Circle().fill(hovering && !disabled ? Theme.Palette.hoverWash : .clear))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .onHover { hovering = $0 }
    .help(help)
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  private var foreground: AnyShapeStyle {
    if disabled { return AnyShapeStyle(Theme.Palette.chromeGlyphDim) }
    if active { return AnyShapeStyle(Theme.Palette.accent) }
    return AnyShapeStyle(hovering ? Theme.Palette.chromeGlyphHover : Theme.Palette.chromeGlyph)
  }
}
```

Every interactive chrome control follows this grammar: plain button style · haptic on tap ·
tooltip via `.help()` (with the shortcut spelled in it: `"Settings  ⌘,"`) · 0.12s hover ·
wash-not-fill. Tool-grid variants use a `RoundedRectangle(cornerRadius: 8)` wash instead of a
circle and may add a bottom-trailing shortcut badge (8pt bold; accent when active, badge
color otherwise). A `busy` variant swaps the glyph for a small `ProgressView` and disables
the button.

### The bottom command bar

One `HStack(spacing: WindowChrome.itemSpacing)` holding clusters separated by dividers,
wrapped in a single `.chromePill()`:

```swift
HStack(spacing: WindowChrome.itemSpacing) {
  /* zoom cluster: out · %label(44pt wide, tap = reset) · in · fit */
  barDivider
  /* the tool grid */
  barDivider
  /* color / utilities */
  barDivider
  /* grounding · settings */
}
.chromePill()
.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
.padding(.bottom, WindowChrome.edgeInset)

var barDivider: some View {
  Rectangle().fill(Theme.Palette.chromeDivider)
    .frame(width: 1, height: 20)
    .padding(.horizontal, 4)
}
```

### The hover-expanding identity pill (top-left)

ONE glass container that grows — never a pill plus a separate popover (a gap between them
flickers on hover-crossing). At rest: the document name at `labelFont`, `labelPadH`
horizontal padding, `controlHeight` tall. On hover the same surface extends downward:
divider · scrollable row list (fixed width ~248, maxHeight 320) · divider · full-width "New"
row. Cap displayed names (~32 chars + ellipsis) so the pill hugs content. Hover handling:
open immediately; close after a **0.18s delay** (cancelable `DispatchWorkItem`) so crossing
the pill→list gap doesn't flicker; a "pinned" flag (inline rename/confirm in progress)
blocks close entirely. Anchor: `.topLeading`, `.padding(.top, edgeInset)`,
`.padding(.leading, trafficLightInset)`, `zIndex(60)`.

### Docked side panels (settings / chat)

Not windows — glass cards inside the canvas, one at a time (opening one closes the other):
width `min(360, max(300, windowWidth * 0.32))` · `.dockPanelSurface()` (radius 22) ·
anchored `.topTrailing` · top padding = 10% of window height · trailing = `edgeInset` ·
bottom = 68pt (clears the command bar) · panel shadow · trailing-slide + fade transition ·
`zIndex(40)`.

### Toast

Bottom-center, above the bar: `HStack(icon tinted, body text)` · padding 14/10 ·
`.composerPopupSurface()` · bottom-slide + fade.

## 8. Keyboard skeleton

If the app has no menu bar, app-menu shortcuts never fire. Catch them in the window's
`performKeyEquivalent` and broadcast `NotificationCenter` events the SwiftUI tree observes
(a clean AppKit→SwiftUI command bridge). Reserve the conventions: ⌘, settings · ⌘K palette ·
⌘N new · ⌘[ / ⌘] prev/next · ⌘1…9 tools · ⌘−/=/0 zoom · ⌘Z/⇧⌘Z undo/redo · Esc dismisses
(drafts first, window last). Gate text-editing shortcuts on `firstResponder is NSTextView`
so typing is never hijacked. Space (held, outside text) latches pan mode via keyDown/keyUp
notifications.

## 9. Rules — each one is a scar

1. **`WindowChrome` is law.** Any inline size/padding/font/radius in a chrome view is a bug,
   even if it currently matches.
2. **One glass recipe.** New surface = `floatingGlass` with a different shape, never a new
   material stack.
3. **No color literals in views.** No hex, no `.white`/`.black`, and never
   `Color.accentColor` — always `Theme.Palette.accent` (flavors may override accent; Catppuccin
   uses mauve).
4. **Active = accent glyph. Hover = neutral wash.** Never a filled/accent background on an
   active control — the fills made the bar read as blueberry buttons.
5. **Every pill through `.chromePill()`.** Hand-assembled surfaces are how four pills became
   four shapes.
6. **Traffic lights re-layout on every delegate event** (§2). AppKit will reset them.
7. **The window stays non-opaque** with a clear backing; the canvas paints its own surface.
8. **Theme switch = full canvas rebuild**; long-lived state lives outside the view tree.
9. **User colors are slot indexes**, resolved at draw time against the active flavor.
10. **Solid fills for floating label chips** — translucency lets their own shadow muddy them.
11. **Light themes: no pure-black ink** (use the #575757 family) and **no element shadows**
    (ink on paper). Dark themes ground elements with soft surface fills + crust shadows.
12. **One bottom bar.** Resist the urge to add a second floating cluster; new hands-on
    controls join the bar behind a divider.
13. Verify visually after chrome edits, in **both** a dark and a light theme: solid canvas,
    one bottom bar, top pills on the traffic-light centerline, no black ink in light mode.

## 10. Porting checklist for a new app

1. Copy the three color files verbatim: the flavor struct + palettes (§5), then rename.
2. Copy `Theme` (tokens, §5–6), `WindowChrome` (§3), `chromePill`/`floatingGlass`/
   `VisualEffectBackground` (§4), and the backdrop view.
3. Build the window: panel subclass (§2) + controller owning show/hide, frame autosave,
   theme application, and the four traffic-light delegate hooks.
4. Root view: `GeometryReader` → `ZStack(.topLeading)` in the layer order of §1.
5. Build chrome from the recipes in §7: identity pill top-left, presence pill top-right,
   one command bar bottom-center, docked panels right.
6. Wire the keyboard bridge (§8).
7. Decide what your canvas *is* (the workspace under the chrome) — everything else in this
   document is independent of it.

The skeleton's promise: every floating thing is the same height, the same distance from its
edge, the same glass, and recolors correctly under any flavor you drop in. If a new view
needed a number that isn't in §3 or §6, the number is probably wrong.
