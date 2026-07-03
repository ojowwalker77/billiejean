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
            // The tonearm IS the seek control: it follows playback, and dragging
            // its headshell scrubs the track.
            BigTonearm(studio: studio,
                       onSeek: { model.seek(toSeconds: $0) },
                       discDiameter: recordSize)
                .frame(width: recordSize, height: recordSize)
        }
        .frame(width: recordSize, height: recordSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Big tonearm — THE seek control

/// Fixed pivot/arm geometry for the tonearm, derived so the stylus tip lands on
/// the record's outer groove (progress 0) and inner groove (progress 1). The arm
/// rotates about a fixed pivot; `angle(for:)` interpolates linearly by progress.
private struct TonearmGeometry {
    let disc: CGFloat
    let center: CGPoint
    let pivot: CGPoint
    let armLength: CGFloat
    let startAngle: Double   // radians, stylus on the OUTER groove (0:00)
    let endAngle: Double     // radians, stylus on the INNER groove (end)

    init(disc: CGFloat) {
        self.disc = disc
        let c = CGPoint(x: disc / 2, y: disc / 2)
        self.center = c
        // Pivot fixed at the platter's upper-right, just off the disc edge — a
        // real ~9" arm base. This point + the two target radii determine the arm
        // length and the two swing angles; the sweep lands ~24°.
        let pivot = CGPoint(x: disc * 0.98, y: disc * 0.06)
        self.pivot = pivot

        let outerR = disc * 0.47      // outer groove — track start
        let innerR = disc * 0.24      // inner groove — track end
        let d = hypot(pivot.x - c.x, pivot.y - c.y)   // pivot→center distance

        // Choose the arm length so both extremes are reachable and the effective
        // sweep is ~24°. Solve the pivot-centered triangle: the stylus sits at
        // radius r from disc center and armLength from the pivot; the angle at
        // the pivot between (pivot→center) and (pivot→stylus) is:
        //   φ(r) = acos((armLength² + d² − r²) / (2·armLength·d))
        // Pick armLength = d − innerR·k so the inner groove is comfortably in
        // reach, then the two φ give the swing.
        let armLength = d - innerR * 0.35
        self.armLength = armLength

        func phi(_ r: CGFloat) -> Double {
            let cosPhi = (armLength * armLength + d * d - r * r) / (2 * armLength * d)
            return acos(Double(min(1, max(-1, cosPhi))))
        }
        // Base direction pivot→center (the arm swings around this line). The
        // stylus is toward the lower-left of the pivot, so both angles are taken
        // on the same side.
        let baseAngle = Double(atan2(c.y - pivot.y, c.x - pivot.x))
        // Outer groove is the wider angle from the pivot→center line; inner is
        // tighter. Swing the arm on the clockwise (screen: +) side.
        self.startAngle = baseAngle + phi(outerR)   // outer groove, 0:00
        self.endAngle = baseAngle + phi(innerR)      // inner groove, end
    }

    /// Arm angle (radians) at playback progress 0…1 — linear interpolation.
    func angle(for progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return startAngle + (endAngle - startAngle) * t
    }

    /// Stylus tip position for a given arm angle.
    func stylus(atAngle a: Double) -> CGPoint {
        CGPoint(x: pivot.x + cos(a) * Double(armLength),
                y: pivot.y + sin(a) * Double(armLength))
    }

    /// Inverse: map a raw arm angle to progress 0…1, clamped to the swing range.
    func progress(forAngle a: Double) -> Double {
        let span = endAngle - startAngle
        guard abs(span) > 1e-6 else { return 0 }
        return min(1, max(0, (a - startAngle) / span))
    }
}

/// The tonearm: pivots about its fixed base, follows playback continuously
/// (extrapolated between 2s polls via a `TimelineView`), and is the SEEK control
/// — dragging its headshell lifts the arm, shows a floating time chip, and on
/// release commits one `seek`, settling back onto the record with the signature
/// spring. There is no progress bar; this arm IS the progress indicator.
@available(macOS 14.2, *)
struct BigTonearm: View {
    var studio: StudioViewModel
    var onSeek: (Double) -> Void
    var discDiameter: CGFloat

    @State private var clock = PlaybackClock()
    /// While dragging: the target progress 0…1 the stylus is being dragged to.
    @State private var dragProgress: Double?

    private var isPlaying: Bool { studio.snapshot?.isPlaying ?? false }
    private var duration: Double { studio.durationSeconds ?? 0 }

    var body: some View {
        let geo = TonearmGeometry(disc: discDiameter)

        return TimelineView(.animation) { timeline in
            let now = timeline.date
            // Feed the clock every tick (cheap; only re-anchors on real change).
            let _ = clock.ingest(position: studio.positionSeconds,
                                  duration: studio.durationSeconds,
                                  isPlaying: isPlaying)

            // The arm angle: the drag target while scrubbing, else the smoothed
            // live playback progress (continuous between 2s polls, poll-snap free;
            // playback-follow is suppressed during a drag).
            let shownProgress = dragProgress ?? clock.smoothProgress(at: now)
            let angle = geo.angle(for: shownProgress)
            let dragging = dragProgress != nil

            ZStack {
                arm(geo: geo, angle: angle, dragging: dragging)
                    .allowsHitTesting(false)

                // Generous 48pt circular hit area riding the headshell — the ONLY
                // draggable target, so the record surface stays untouched.
                Circle()
                    .fill(.clear)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
                    .position(geo.stylus(atAngle: angle))
                    .gesture(dragGesture(geo: geo))

                if dragging {
                    timeChip(geo: geo, angle: angle)
                }
            }
            .frame(width: discDiameter, height: discDiameter)
        }
        .frame(width: discDiameter, height: discDiameter)
    }

    // MARK: Arm rendering

    @ViewBuilder
    private func arm(geo: TonearmGeometry, angle: Double, dragging: Bool) -> some View {
        let stylus = geo.stylus(atAngle: angle)
        let pivot = geo.pivot
        let armAngle = Angle.radians(atan2(stylus.y - pivot.y, stylus.x - pivot.x))
        // Counterweight stub behind the pivot, opposite the head.
        let backLen = discDiameter * 0.12
        let backPoint = CGPoint(
            x: pivot.x - cos(armAngle.radians) * backLen,
            y: pivot.y - sin(armAngle.radians) * backLen
        )
        // Lifted (dragging) → the arm is off the record: shadow grows + offsets,
        // headshell scales up, the stylus glow disappears.
        let lift: CGFloat = dragging ? 1 : 0

        ZStack {
            // Arm (pivot → stylus)
            Path { p in
                p.move(to: pivot)
                p.addLine(to: stylus)
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

            // Stylus contact glow — present only while the needle is ON the record.
            Circle()
                .fill(Theme.Palette.accent)
                .frame(width: 8, height: 8)
                .blur(radius: 3)
                .opacity(dragging ? 0 : (isPlaying ? 0.7 : 0.35))
                .position(stylus)
                .animation(.easeOut(duration: 0.25), value: dragging)

            // Angled headshell at the tip
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.Palette.body)
                .frame(width: discDiameter * 0.04, height: discDiameter * 0.085)
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.Palette.chromeGlyphHover.opacity(0.25))
                        .frame(width: discDiameter * 0.016, height: discDiameter * 0.028)
                        .offset(y: -discDiameter * 0.016)
                )
                .scaleEffect(dragging ? 1.06 : 1.0)
                .rotationEffect(armAngle + .degrees(90 + 14))
                .position(stylus)
                .animation(ChromeMotion.spring, value: dragging)

            // Pivot base
            Circle()
                .fill(Theme.Palette.rowFill)
                .overlay(Circle().strokeBorder(Theme.Palette.panelHairline, lineWidth: 1))
                .frame(width: 13, height: 13)
                .position(pivot)
        }
        .frame(width: discDiameter, height: discDiameter)
        // Drop shadow on the platter grows + offsets as the arm lifts.
        .shadow(color: .black.opacity(dragging ? 0.32 : 0.20),
                radius: 2 + lift * 5, y: 1 + lift * 4)
        .animation(ChromeMotion.spring, value: dragging)
    }

    // MARK: Floating time chip (solid surface — rule 10)

    @ViewBuilder
    private func timeChip(geo: TonearmGeometry, angle: Double) -> some View {
        let stylus = geo.stylus(atAngle: angle)
        let target = (dragProgress ?? 0) * duration
        Text(Self.time(target))
            .font(WindowChrome.labelFont.monospacedDigit())
            .foregroundStyle(Theme.Palette.body)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.Palette.chipFill)               // SOLID (never translucent)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            )
            .fixedSize()
            // Float just above the headshell, clamped inside the platter.
            .position(x: min(discDiameter - 30, max(30, stylus.x)),
                      y: max(16, stylus.y - 30))
            .allowsHitTesting(false)
    }

    // MARK: Drag-to-seek

    private func dragGesture(geo: TonearmGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                // Pointer → angle around the pivot → clamped progress.
                let a = atan2(g.location.y - geo.pivot.y, g.location.x - geo.pivot.x)
                dragProgress = geo.progress(forAngle: Double(a))
            }
            .onEnded { _ in
                let target = dragProgress
                if let target, duration > 0 {
                    // Anchor the smoothed follow at the release position so the
                    // arm settles there (signature spring) instead of snapping to
                    // the now-stale poll; commit the seek once, with a haptic.
                    clock.resetSmoothed(to: target)
                    Haptics.level()
                    onSeek(target * duration)
                }
                withAnimation(ChromeMotion.spring) { dragProgress = nil }
            }
    }

    private static func time(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
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

    /// Live clock for the elapsed readout — same extrapolation as the tonearm.
    @State private var clock = PlaybackClock()

    var body: some View {
        // Deck faceplate: identity up top, VU + lights, then the whole control
        // cluster anchored to the BOTTOM so the panel reads dense, not hollow.
        VStack(alignment: .leading, spacing: 16) {
            trackBlock
            VUMeter(studio: studio)
                .frame(height: 74)
                .frame(maxWidth: .infinity)
            indicatorLights

            Spacer(minLength: 12)

            // Lower cluster — bottom-anchored deck controls.
            VStack(spacing: 16) {
                transport
                elapsedRow
                knobs
                abToggle
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 22)
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

    // 4. Transport — real 3D deck keys.
    private var transport: some View {
        HStack(spacing: 20) {
            Spacer(minLength: 0)
            DeckButton(symbol: "backward.fill", help: "Previous  ⌘←",
                       diameter: 44, glyphSize: 15) {
                model.previousTrack()
            }
            DeckButton(symbol: isPlaying ? "pause.fill" : "play.fill",
                       help: "Play / Pause  Space",
                       diameter: 54, glyphSize: 20) {
                model.playPause()
            }
            DeckButton(symbol: "forward.fill", help: "Next  ⌘→",
                       diameter: 44, glyphSize: 15) {
                model.nextTrack()
            }
            Spacer(minLength: 0)
        }
    }

    // 5. Elapsed / total — small monospaced text (the tonearm IS the progress bar).
    //    Elapsed is live via the same extrapolation the tonearm uses.
    private var elapsedRow: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let _ = clock.ingest(position: studio.positionSeconds,
                                 duration: studio.durationSeconds,
                                 isPlaying: isPlaying)
            let elapsed = clock.position(at: timeline.date)
            HStack {
                Text(Self.time(elapsed))
                    .font(WindowChrome.labelFont.monospacedDigit())
                    .foregroundStyle(Theme.Palette.chromeText)
                Spacer(minLength: 0)
                Text(Self.time(studio.durationSeconds))
                    .font(WindowChrome.labelFont.monospacedDigit())
                    .foregroundStyle(Theme.Palette.chromeText)
            }
        }
        .frame(height: 16)
    }

    // 6. Three physical knobs (44pt).
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
        PhysicalKnob(help: help, value: value, onReset: reset, size: 44, label: title)
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

/// A physical indicator lens + caption. ON: a lit 8pt lens — radial gradient
/// (bright accent core → darkened accent edge), 1pt dark rim, and an outer glow.
/// OFF: a dark unlit lens (surface0 core, same rim), never a flat gray dot.
@available(macOS 14.2, *)
struct IndicatorLight: View {
    let label: String
    let on: Bool

    var body: some View {
        VStack(spacing: 5) {
            lens
            Text(label)
                .font(WindowChrome.microFont)
                .foregroundStyle(Theme.Palette.count)
        }
        .animation(ChromeMotion.hover, value: on)
    }

    private var lens: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: on
                        ? [Theme.Palette.accent, Theme.Palette.accent.darkened(by: 0.45)]
                        : [Theme.Palette.lensOff, Theme.Palette.lensOff.darkened(by: 0.3)]),
                    center: UnitPoint(x: 0.4, y: 0.35),
                    startRadius: 0,
                    endRadius: 5
                )
            )
            .overlay(Circle().strokeBorder(Theme.Palette.lensRim, lineWidth: 1))
            .frame(width: 8, height: 8)
            .shadow(color: on ? Theme.Palette.accent.opacity(0.5) : .clear,
                    radius: on ? 5 : 0)
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

    private let radius = WindowChrome.inBarHoverRadius

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { _ in
            // Sample + smooth the live output level once per tick (asymmetric).
            let level = smoother.advance(toward: Double(studio.outputLevel()).clamped01)
            face(level: level)
        }
    }

    private func face(level: Double) -> some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let pivot = CGPoint(x: w / 2, y: h - 8)
            let r = min(w / 2 - 10, h - 14)

            let start = Angle.degrees(-135)
            let end = Angle.degrees(-45)

            // Arc scale.
            var scale = Path()
            scale.addArc(center: pivot, radius: r,
                         startAngle: start, endAngle: end, clockwise: false)
            ctx.stroke(scale, with: .color(Theme.Palette.count),
                       style: StrokeStyle(lineWidth: 1))

            // Red zone (last ~22% of the sweep).
            var red = Path()
            red.addArc(center: pivot, radius: r,
                       startAngle: .degrees(-45 - 90 * 0.22), endAngle: end, clockwise: false)
            ctx.stroke(red, with: .color(Theme.Palette.tint(0)),
                       style: StrokeStyle(lineWidth: 2))

            // Major + minor tick marks.
            let majors = 5
            let minorsPer = 2
            let totalSteps = (majors - 1) * (minorsPer + 1)
            for i in 0...totalSteps {
                let t = Double(i) / Double(totalSteps)
                let a = Angle.degrees(-135 + 90 * t).radians
                let isMajor = i % (minorsPer + 1) == 0
                let len: CGFloat = isMajor ? 6 : 3
                let inner = r - len
                let p1 = CGPoint(x: pivot.x + cos(a) * inner, y: pivot.y + sin(a) * inner)
                let p2 = CGPoint(x: pivot.x + cos(a) * r, y: pivot.y + sin(a) * r)
                var tick = Path()
                tick.move(to: p1)
                tick.addLine(to: p2)
                ctx.stroke(tick, with: .color(Theme.Palette.chromeText),
                           style: StrokeStyle(lineWidth: isMajor ? 1.5 : 1))
            }

            // Needle: 0…1 → −135°…−45° in canvas space.
            let needleAngle = Angle.degrees(-135 + 90 * level).radians
            let needleLen = r - 2
            let tip = CGPoint(x: pivot.x + cos(needleAngle) * needleLen,
                              y: pivot.y + sin(needleAngle) * needleLen)
            var needle = Path()
            needle.move(to: pivot)
            needle.addLine(to: tip)
            ctx.stroke(needle, with: .color(Theme.Palette.body),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            // Pivot screw: 5pt dark circle + 1pt light dot slightly off-center.
            let screw = CGRect(x: pivot.x - 2.5, y: pivot.y - 2.5, width: 5, height: 5)
            ctx.fill(Path(ellipseIn: screw), with: .color(Theme.Palette.knobBody))
            let dot = CGRect(x: pivot.x - 1.4, y: pivot.y - 1.6, width: 1.2, height: 1.2)
            ctx.fill(Path(ellipseIn: dot), with: .color(Theme.Palette.knobHighlight))
        }
        .background(plate)
        .overlay(sheen)
        .overlay(alignment: .bottomTrailing) {
            Text("VU")
                .font(WindowChrome.microFont)
                .foregroundStyle(Theme.Palette.count)
                .padding(.trailing, 7)
                .padding(.bottom, 5)
        }
    }

    // Physical plate: rowFill with a 1pt inner shadow ring.
    private var plate: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.Palette.rowFill)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.Palette.vuInnerShadow, lineWidth: 1)
                    .blur(radius: 1)
                    .mask(RoundedRectangle(cornerRadius: radius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.Palette.panelHairline, lineWidth: 1)
            )
    }

    // Diagonal glass-sheen streak (non-interactive), top-left → center.
    private var sheen: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
                LinearGradient(colors: [Theme.Palette.vuGlassSheen, .clear],
                               startPoint: .topLeading, endPoint: .center)
            )
            .allowsHitTesting(false)
    }
}

/// Asymmetric exponential smoothing for the VU needle: fast attack (τ≈0.10s),
/// slow release (τ≈0.45s), at the 20 Hz poll rate. A class so the TimelineView
/// redraws mutate one shared instance instead of writing @State during a redraw.
final class MeterSmoother {
    private var value: Double = 0

    // Per-tick coefficients for dt = 1/20s: α = 1 − exp(−dt/τ).
    // attack τ = 0.10 → α ≈ 0.393 ; release τ = 0.45 → α ≈ 0.105.
    private static let attack = 0.393
    private static let release = 0.105

    /// One smoothing step toward `target`; returns the new needle position 0…1.
    func advance(toward target: Double) -> Double {
        let a = target > value ? Self.attack : Self.release
        value += (target - value) * a
        value = value.clamped01
        return value
    }
}
