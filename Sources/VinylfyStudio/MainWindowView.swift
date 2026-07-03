import SwiftUI
import AppKit
import NowPlaying

// MARK: - Keyboard bridge notifications

extension Notification.Name {
    static let billiePlayPause = Notification.Name("billie.playPause")
    static let billiePrev = Notification.Name("billie.prev")
    static let billieNext = Notification.Name("billie.next")
    static let billieLibrary = Notification.Name("billie.library")
    static let billieSettings = Notification.Name("billie.settings")
    /// Posted after a canvas-state transition so the window controller can
    /// re-layout the traffic lights once SwiftUI has rebuilt the content.
    static let billieRelayoutChrome = Notification.Name("billie.relayoutChrome")
}

// MARK: - Root

/// The main window content: solid themed canvas filling every pixel, with all
/// chrome floating over it as glass pills. Layer order per skeleton §1.
@available(macOS 14.2, *)
struct MainWindowView: View {
    @State private var model = MainViewModel()
    @AppStorage(ActiveTheme.storageKey) private var flavorRaw = ActiveTheme.selected.rawValue

    /// Manual widget-visibility toggle (top-right) and the settings toggle both
    /// call into the controller via these closures, injected by the host.
    var onToggleWidget: () -> Void = {}
    var showWidgetOnMinimize: Binding<Bool>

    @State private var showingFlavorMenu = false
    @State private var showingSettingsMenu = false

    private var studio: StudioViewModel { model.studio }

    private var isPlayer: Bool {
        if case .player = model.state { return true }
        return false
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Layer: canvas backdrop
                PanelBackground()

                // Layer: canvas content
                canvas(geo: geo)
                    .zIndex(0)

                // Layer: top-left identity pill
                identityPill
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, WindowChrome.edgeInset)
                    .padding(.leading, WindowChrome.trafficLightInset)
                    .zIndex(60)

                // Layer: top-right presence pill
                presencePill
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, WindowChrome.edgeInset)
                    .padding(.trailing, WindowChrome.edgeInset)
                    .zIndex(50)

                // Layer: bottom command bar — NOT in player (the turntable is the instrument).
                if !isPlayer {
                    CommandBar(model: model,
                               showSettings: $showingSettingsMenu,
                               showWidgetOnMinimize: showWidgetOnMinimize)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, WindowChrome.edgeInset)
                        .transition(.opacity)
                        .zIndex(30)
                }

                // Layer: toast
                if let toast = model.toast {
                    ToastView(symbol: toast.symbol, message: toast.message)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, WindowChrome.panelBottomClearance + WindowChrome.edgeInset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(80)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { model.loadPlaylistsIfNeeded() }
        .onChange(of: model.state) { _, _ in
            // The content rebuilds on transition; re-layout the traffic lights
            // after SwiftUI has applied the change.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .billieRelayoutChrome, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .billiePlayPause)) { _ in
            model.playPause()
        }
        .onReceive(NotificationCenter.default.publisher(for: .billiePrev)) { _ in
            model.previousTrack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .billieNext)) { _ in
            model.nextTrack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .billieLibrary)) { _ in
            model.backToLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(for: .billieSettings)) { _ in
            showingSettingsMenu.toggle()
        }
    }

    // MARK: - Canvas (two states)

    @ViewBuilder
    private func canvas(geo: GeometryProxy) -> some View {
        switch model.state {
        case .library:
            LibraryCanvas(model: model)
                .transition(.opacity)
        case .songGrid(let id):
            SongGridCanvas(model: model, playlistID: id)
                .transition(.opacity)
        case .player:
            PlayerCanvas(model: model, canvasHeight: geo.size.height, canvasWidth: geo.size.width)
                .transition(.opacity)
        }
    }

    // MARK: - Identity pill (top-left) — hover-expanding playlist picker

    private var identityPill: some View {
        IdentityPicker(model: model)
    }

    // MARK: - Presence pill (top-right)

    private var presencePill: some View {
        HStack(spacing: WindowChrome.itemSpacing) {
            ChromeIconButton(symbol: "paintpalette", help: "Theme", active: showingFlavorMenu) {
                showingFlavorMenu.toggle()
            }
            .popover(isPresented: $showingFlavorMenu, arrowEdge: .bottom) {
                flavorMenu
            }
            ChromeIconButton(symbol: "rectangle.bottomthird.inset.filled",
                             help: "Show floating widget") {
                onToggleWidget()
            }
        }
        .chromePill()
    }

    private var flavorMenu: some View {
        GlassMenu {
            ForEach(Flavor.allCases) { flavor in
                GlassMenuRow(title: flavor.displayName,
                             checked: flavor.rawValue == flavorRaw) {
                    flavorRaw = flavor.rawValue
                    ActiveTheme.set(flavor)
                    NotificationCenter.default.post(name: .billieFlavorChanged, object: nil)
                    showingFlavorMenu = false
                }
            }
        }
        .padding(8)
    }
}

extension Notification.Name {
    /// Posted when the flavor changes; the window controller rebuilds content.
    static let billieFlavorChanged = Notification.Name("billie.flavorChanged")
}

// MARK: - Library canvas

@available(macOS 14.2, *)
struct LibraryCanvas: View {
    @Bindable var model: MainViewModel

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 200), spacing: 28)]

    var body: some View {
        if model.musicNotRunning && model.playlists.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 34) {
                    ForEach(model.playlists) { playlist in
                        SleeveCell(
                            title: playlist.name,
                            subtitle: "\(playlist.trackCount) track\(playlist.trackCount == 1 ? "" : "s")",
                            artwork: model.artworkImage(for: playlist.id),
                            onOpen: { model.openSongGrid(playlist) },
                            onPlay: { model.play(playlist) },
                            onAppear: { model.loadArtwork(for: playlist) }
                        )
                    }
                }
                .padding(.horizontal, 40)
                // Clear of top pills and bottom command bar.
                .padding(.top, WindowChrome.pillHeight + WindowChrome.edgeInset * 2)
                .padding(.bottom, WindowChrome.panelBottomClearance + WindowChrome.edgeInset)
            }
            .scrollIndicators(.never)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Palette.count)
            Text("Music isn't running")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.body)
            Text("Open Music to see your playlists as record sleeves.")
                .font(WindowChrome.labelFont)
                .foregroundStyle(Theme.Palette.menuDesc)
                .multilineTextAlignment(.center)
            OpenMusicButton { model.openMusic() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A primary glass action button for the empty state.
@available(macOS 14.2, *)
struct OpenMusicButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            HStack(spacing: 6) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 15, weight: .medium))
                Text("Open Music")
                    .font(WindowChrome.labelFont)
            }
            .foregroundStyle(hovering ? Theme.Palette.chromeGlyphHover : Theme.Palette.body)
            .padding(.horizontal, 14)
            .frame(height: WindowChrome.controlHeight)
            .chromePill()
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ChromeMotion.hover, value: hovering)
    }
}

// MARK: - Song grid canvas

/// The song picker: the same sleeve grid, one cover per TRACK of a playlist.
/// Cover tap plays the track · play button plays the track.
@available(macOS 14.2, *)
struct SongGridCanvas: View {
    @Bindable var model: MainViewModel
    let playlistID: String

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 200), spacing: 28)]

    var body: some View {
        let tracks = model.tracks(for: playlistID)
        ScrollView {
            if tracks.isEmpty {
                loading
            } else {
                LazyVGrid(columns: columns, spacing: 34) {
                    ForEach(tracks) { track in
                        SleeveCell(
                            title: track.name,
                            subtitle: track.artist,
                            artwork: model.trackArtworkImage(for: track.id),
                            onOpen: { model.playTrack(track, inPlaylist: playlistID) },
                            onPlay: { model.playTrack(track, inPlaylist: playlistID) },
                            onAppear: { model.loadTrackArtwork(track, inPlaylist: playlistID) }
                        )
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, WindowChrome.pillHeight + WindowChrome.edgeInset * 2)
                .padding(.bottom, WindowChrome.panelBottomClearance + WindowChrome.edgeInset)
            }
        }
        .scrollIndicators(.never)
    }

    private var loading: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text("Loading tracks…")
                .font(WindowChrome.labelFont)
                .foregroundStyle(Theme.Palette.menuDesc)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(.top, WindowChrome.pillHeight + WindowChrome.edgeInset * 2)
    }
}

// MARK: - Identity picker (hover-expanding playlist list)

/// ONE glass surface that GROWS on hover into a playlist picker. Collapsed face
/// is "billiejean" (library) or a back-chevron + playlist name (songGrid/player).
/// On hover the same surface extends downward with a divider + scrollable list.
@available(macOS 14.2, *)
struct IdentityPicker: View {
    @Bindable var model: MainViewModel

    @State private var open = false
    @State private var closeWork: DispatchWorkItem?

    private var isLibrary: Bool {
        if case .library = model.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            faceRow
            if open {
                // Fixed width — the expanded body must never inherit the
                // window's width (a bare Rectangle is greedy and would).
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle()
                        .fill(Theme.Palette.separator)
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                    list
                }
                .frame(width: 248, alignment: .leading)
            }
        }
        .composerPopupSurface(radius: WindowChrome.radius)
        .help(open ? "" : (isLibrary ? "billiejean" : model.currentPlaylistName))
        .onHover { hovering in
            if hovering {
                closeWork?.cancel()
                withAnimation(.easeOut(duration: 0.16)) { open = true }
            } else {
                let work = DispatchWorkItem {
                    withAnimation(.easeOut(duration: 0.16)) { open = false }
                }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            }
        }
    }

    // Collapsed face: never shifts when the list appears (stays at VStack top).
    private var faceRow: some View {
        HStack(spacing: WindowChrome.itemSpacing) {
            if !isLibrary {
                // Tooltip suppressed while the picker is open (owner contract).
                ChromeIconButton(symbol: "chevron.left", help: open ? "" : "Back  ⌘1") {
                    model.back()
                }
            }
            ChromeTextLabel(text: isLibrary ? "billiejean" : cap(model.currentPlaylistName))
        }
        .padding(.horizontal, WindowChrome.padH)
        .padding(.vertical, WindowChrome.padV)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.playlists) { playlist in
                    IdentityPickerRow(
                        name: cap(playlist.name, 32),
                        current: playlist.id == model.currentPlaylistID,
                        action: {
                            closeWork?.cancel()
                            withAnimation(.easeOut(duration: 0.16)) { open = false }
                            model.openSongGrid(playlist)
                        }
                    )
                }
            }
            .padding(6)
        }
        .frame(width: 248)
        .frame(maxHeight: 320)
    }

    private func cap(_ s: String, _ maxLen: Int = 28) -> String {
        s.count <= maxLen ? s : String(s.prefix(maxLen - 1)) + "…"
    }
}

@available(macOS 14.2, *)
struct IdentityPickerRow: View {
    let name: String
    let current: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(current ? Theme.Palette.accent : .clear)
                    .frame(width: 5, height: 5)
                Text(name)
                    .font(WindowChrome.labelFont)
                    .foregroundStyle(Theme.Palette.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
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

// MARK: - Player canvas

@available(macOS 14.2, *)
struct PlayerCanvas: View {
    @Bindable var model: MainViewModel
    let canvasHeight: CGFloat
    let canvasWidth: CGFloat

    private var studio: StudioViewModel { model.studio }

    private var playlistID: String? {
        if case .player(let id) = model.state { return id }
        return nil
    }

    private var artwork: NSImage? {
        studio.artworkImage ?? playlistID.flatMap { model.artworkImage(for: $0) }
    }

    private var dominant: Color? {
        studio.dominantColor ?? playlistID.flatMap { model.dominantColor(for: $0) }
    }

    /// The control panel takes ~38% of the canvas (floored so controls fit).
    private var panelWidth: CGFloat {
        max(300, canvasWidth * 0.38 - WindowChrome.edgeInset * 2)
    }

    /// Platter diameter: the owner's `min(canvasHeight * 0.62, 460)`, further
    /// clamped so it always fits the left region at small window sizes.
    private var recordSize: CGFloat {
        let vertical = canvasHeight - WindowChrome.edgeInset * 2
        let horizontal = canvasWidth - panelWidth - WindowChrome.edgeInset * 3
        return max(160, min(canvasHeight * 0.62, 460, vertical, horizontal))
    }

    var body: some View {
        // The panel runs the canvas height minus edge insets (V5); the platter
        // centers in the remaining ~62%.
        HStack(spacing: WindowChrome.edgeInset) {
            platter
                .frame(maxWidth: .infinity)

            TurntablePanel(model: model)
                .frame(width: panelWidth)
        }
        .padding(WindowChrome.edgeInset)
    }

    private var platter: some View {
        ZStack {
            PlayerRecord(
                diameter: recordSize,
                artwork: artwork,
                dominant: dominant,
                spinning: studio.isSpinning,
                cold: studio.bypass
            )
            // Large tonearm overlapping the platter from the right.
            BigTonearm(engaged: studio.snapshot?.isPlaying ?? false, discDiameter: recordSize)
                .frame(width: recordSize, height: recordSize)
        }
        .frame(width: recordSize, height: recordSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Big tonearm (turntable, larger + more detailed than RecordView's)

/// A detailed tonearm pivoting from the platter's upper-right: pivot base with a
/// counterweight behind it, a straight arm, and an angled headshell at the tip.
/// Rests on the record when playing; lifts ~14° around the pivot when paused.
@available(macOS 14.2, *)
struct BigTonearm: View {
    var engaged: Bool
    var discDiameter: CGFloat

    var body: some View {
        let center = CGPoint(x: discDiameter / 2, y: discDiameter / 2)
        // Pivot sits at the platter's upper-right, just inside the panel edge.
        let pivot = CGPoint(x: discDiameter * 0.94, y: discDiameter * 0.10)
        let seat = discDiameter * 0.36
        // Head rests around the record's 1–2 o'clock outer third.
        let headPoint = CGPoint(
            x: center.x + cos(.pi / 3.4) * seat,
            y: center.y - sin(.pi / 3.4) * seat
        )
        let armAngle = Angle.radians(atan2(headPoint.y - pivot.y, headPoint.x - pivot.x))
        // Counterweight lies behind the pivot, opposite the head.
        let backLen = discDiameter * 0.12
        let backPoint = CGPoint(
            x: pivot.x - cos(armAngle.radians) * backLen,
            y: pivot.y - sin(armAngle.radians) * backLen
        )

        return ZStack {
            // Arm (pivot → head)
            Path { p in
                p.move(to: pivot)
                p.addLine(to: headPoint)
            }
            .stroke(Theme.Palette.body, style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // Counterweight stub behind the pivot
            Path { p in
                p.move(to: pivot)
                p.addLine(to: backPoint)
            }
            .stroke(Theme.Palette.body, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            Circle()
                .fill(Theme.Palette.body)
                .frame(width: discDiameter * 0.06, height: discDiameter * 0.06)
                .position(backPoint)

            // Angled headshell at the tip
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.Palette.body)
                .frame(width: discDiameter * 0.035, height: discDiameter * 0.075)
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.Palette.chromeGlyphHover.opacity(0.25))
                        .frame(width: discDiameter * 0.015, height: discDiameter * 0.025)
                        .offset(y: -discDiameter * 0.015)
                )
                .rotationEffect(armAngle + .degrees(90 + 14))   // angled headshell
                .position(headPoint)

            // Pivot base
            Circle()
                .fill(Theme.Palette.rowFill)
                .overlay(Circle().strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
                .frame(width: 12, height: 12)
                .position(pivot)
        }
        .frame(width: discDiameter, height: discDiameter)
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        .rotationEffect(.degrees(engaged ? 0 : -14),
                        anchor: UnitPoint(x: 0.94, y: 0.10))
        .animation(ChromeMotion.spring, value: engaged)
        .allowsHitTesting(false)
    }
}

// MARK: - Turntable control panel (the vertical instrument panel, right side)

/// ONE dock-panel glass card running the canvas height, holding the track block,
/// VU meter, indicator lights, transport, seek, three physical knobs, and the
/// A/B toggle — all on the WindowChrome grid.
@available(macOS 14.2, *)
struct TurntablePanel: View {
    @Bindable var model: MainViewModel

    private var studio: StudioViewModel { model.studio }
    private var isPlaying: Bool { studio.snapshot?.isPlaying ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            trackBlock
            VUMeter(studio: studio)
                .frame(width: 120, height: 64)
                .frame(maxWidth: .infinity)
            indicatorLights
            Spacer(minLength: 8)
            transport
            seek
            knobs
            abToggle
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        // The presence pill floats over the panel's top-right; start the content
        // below its band so the track block never runs under it.
        .padding(.top, WindowChrome.pillHeight + 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .dockPanelSurface(radius: WindowChrome.panelRadius)
        .shadow(color: Theme.Shadow.panel.color, radius: Theme.Shadow.panel.radius, y: Theme.Shadow.panel.y)
    }

    // 1. Track block
    private var trackBlock: some View {
        let snap = studio.snapshot
        return VStack(alignment: .leading, spacing: 3) {
            Text(snap?.title ?? "—")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(secondaryLine(snap))
                .font(WindowChrome.labelFont)
                .foregroundStyle(Theme.Palette.menuDesc)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(model.currentPlaylistName)
                .font(WindowChrome.sublabelFont)
                .foregroundStyle(Theme.Palette.count)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(snap?.title ?? "")
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.35), value: snap?.title)
    }

    private func secondaryLine(_ snap: NowPlayingSnapshot?) -> String {
        guard let snap else { return " " }
        var parts = [snap.artist]
        if let genre = snap.genre, !genre.isEmpty { parts.append(genre) }
        return parts.joined(separator: " · ")
    }

    // 3. Indicator lights
    private var indicatorLights: some View {
        HStack(spacing: 28) {
            IndicatorLight(label: "POWER", on: studio.isRunning)
            IndicatorLight(label: "VINYL", on: !studio.bypass)
        }
        .frame(maxWidth: .infinity)
    }

    // 4. Transport
    private var transport: some View {
        HStack(spacing: WindowChrome.itemSpacing) {
            Spacer(minLength: 0)
            ChromeIconButton(symbol: "backward.fill", help: "Previous  ⌘←") {
                model.previousTrack()
            }
            ChromeIconButton(symbol: isPlaying ? "pause.fill" : "play.fill",
                             help: "Play / Pause  Space",
                             diameter: WindowChrome.deckControlHeight) {
                model.playPause()
            }
            ChromeIconButton(symbol: "forward.fill", help: "Next  ⌘→") {
                model.nextTrack()
            }
            Spacer(minLength: 0)
        }
    }

    // 5. Seek
    private var seek: some View {
        HStack(spacing: 8) {
            Text(Self.time(studio.positionSeconds))
                .font(WindowChrome.labelFont.monospacedDigit())
                .foregroundStyle(Theme.Palette.chromeText)
                .frame(width: 40, alignment: .trailing)
            GeometryReader { geo in
                SeekSlider(
                    position: studio.positionSeconds,
                    duration: studio.durationSeconds,
                    onSeek: { model.seek(toSeconds: $0) },
                    width: geo.size.width
                )
            }
            .frame(height: WindowChrome.controlHeight)
            Text(Self.time(studio.durationSeconds))
                .font(WindowChrome.labelFont.monospacedDigit())
                .foregroundStyle(Theme.Palette.chromeText)
                .frame(width: 40, alignment: .leading)
        }
    }

    // 6. Three physical knobs
    private var knobs: some View {
        HStack(spacing: 0) {
            knob("Noise", help: "Noise — scroll to adjust, double-click to reset",
                 value: Binding(get: { studio.noise }, set: { studio.noise = $0 }),
                 reset: studio.resetNoise)
            knob("Main", help: "Main — scroll to adjust, double-click to reset",
                 value: Binding(get: { studio.main }, set: { studio.main = $0 }),
                 reset: studio.resetMain)
            knob("Volume", help: "Volume — scroll to adjust, double-click to reset",
                 value: Binding(get: { studio.volume }, set: { studio.volume = $0 }),
                 reset: studio.resetVolume)
        }
        .frame(maxWidth: .infinity)
    }

    private func knob(_ title: String, help: String,
                      value: Binding<Double>, reset: @escaping () -> Void) -> some View {
        MiniKnob(title: title, help: help, value: value, onReset: reset, size: 40, label: title)
            .frame(maxWidth: .infinity)
    }

    // 7. A/B toggle as a labeled glyph button
    private var abToggle: some View {
        ABToggle(on: !studio.bypass) { studio.toggleBypass() }
    }

    private static func time(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A small indicator dot + caption.
@available(macOS 14.2, *)
struct IndicatorLight: View {
    let label: String
    let on: Bool
    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(on ? Theme.Palette.accent : Theme.Palette.chromeGlyphDim)
                .frame(width: 6, height: 6)
            Text(label)
                .font(WindowChrome.microFont)
                .foregroundStyle(Theme.Palette.count)
        }
        .animation(ChromeMotion.hover, value: on)
    }
}

/// The A/B toggle as a labeled glyph button (glyph + caption, no filled circle).
@available(macOS 14.2, *)
struct ABToggle: View {
    let on: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            VStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(WindowChrome.iconFont)
                    .foregroundStyle(glyph)
                Text(on ? "VINYL" : "ORIGINAL")
                    .font(WindowChrome.microFont)
                    .foregroundStyle(on ? Theme.Palette.accent : Theme.Palette.count)
            }
            .frame(width: 56, height: 48)
            .background(
                RoundedRectangle(cornerRadius: WindowChrome.inBarHoverRadius, style: .continuous)
                    .fill(hovering ? Theme.Palette.hoverWash : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ChromeMotion.hover, value: hovering)
        .help(on ? "Vinyl — tap for Original" : "Original — tap for Vinyl")
    }

    private var glyph: Color {
        if on { return Theme.Palette.accent }
        return hovering ? Theme.Palette.chromeGlyphHover : Theme.Palette.chromeGlyph
    }
}

// MARK: - VU meter (arc scale + live needle)

/// A light-faced VU meter: arc scale with tick marks, a red zone at the top, and
/// a needle driven by the live output level (smoothed) from a 20 Hz timeline.
@available(macOS 14.2, *)
struct VUMeter: View {
    var studio: StudioViewModel
    /// Class-held smoothing state (like InertialSpinner): TimelineView redraws
    /// mutate the same instance — @State must never mutate during render.
    @State private var smoother = MeterSmoother()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { _ in
            // Sample + smooth the live output level once per tick.
            let level = smoother.advance(toward: Double(studio.outputLevel()).clamped01)
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                let pivot = CGPoint(x: w / 2, y: h - 6)
                let radius = min(w / 2 - 8, h - 12)

                // Arc scale (−45°…+45°, measured from straight up).
                let start = Angle.degrees(-135)
                let end = Angle.degrees(-45)
                var scale = Path()
                scale.addArc(center: pivot, radius: radius,
                             startAngle: start, endAngle: end, clockwise: false)
                ctx.stroke(scale, with: .color(Theme.Palette.count),
                           style: StrokeStyle(lineWidth: 1))

                // Red zone at the top of the scale (last ~22%).
                var red = Path()
                red.addArc(center: pivot, radius: radius,
                           startAngle: .degrees(-45 - 90 * 0.22), endAngle: end, clockwise: false)
                ctx.stroke(red, with: .color(Theme.Palette.tint(0)),
                           style: StrokeStyle(lineWidth: 2))

                // Tick marks along the scale.
                let ticks = 9
                for i in 0..<ticks {
                    let t = Double(i) / Double(ticks - 1)
                    let a = Angle.degrees(-135 + 90 * t).radians
                    let inner = radius - 4
                    let p1 = CGPoint(x: pivot.x + cos(a) * inner, y: pivot.y + sin(a) * inner)
                    let p2 = CGPoint(x: pivot.x + cos(a) * radius, y: pivot.y + sin(a) * radius)
                    var tick = Path()
                    tick.move(to: p1)
                    tick.addLine(to: p2)
                    ctx.stroke(tick, with: .color(Theme.Palette.chromeText),
                               style: StrokeStyle(lineWidth: 1))
                }

                // Needle: 0…1 → −45°…+45° from vertical (i.e. −135°…−45° in canvas).
                let needleAngle = Angle.degrees(-135 + 90 * level).radians
                let needleLen = radius - 2
                let tip = CGPoint(x: pivot.x + cos(needleAngle) * needleLen,
                                  y: pivot.y + sin(needleAngle) * needleLen)
                var needle = Path()
                needle.move(to: pivot)
                needle.addLine(to: tip)
                ctx.stroke(needle, with: .color(Theme.Palette.body),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            .background(
                RoundedRectangle(cornerRadius: WindowChrome.inBarHoverRadius, style: .continuous)
                    .fill(Theme.Palette.rowFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: WindowChrome.inBarHoverRadius, style: .continuous)
                            .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1)
                    )
            )
        }
    }
}

/// Exponential-approach smoothing for the VU needle. A class so the 20 Hz
/// TimelineView redraws mutate one shared instance (the InertialSpinner pattern)
/// instead of writing @State during a view update.
final class MeterSmoother {
    private var value: Double = 0

    /// One smoothing step toward `target`; returns the new needle position 0…1.
    func advance(toward target: Double) -> Double {
        value += (target - value) * 0.3
        value = value.clamped01
        return value
    }
}
