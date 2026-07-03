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

                // Layer: bottom command bar
                CommandBar(model: model,
                           showSettings: $showingSettingsMenu,
                           showWidgetOnMinimize: showWidgetOnMinimize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, WindowChrome.edgeInset)
                    .zIndex(30)

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
        case .player:
            PlayerCanvas(model: model, canvasHeight: geo.size.height)
                .transition(.opacity)
        }
    }

    // MARK: - Identity pill (top-left)

    @ViewBuilder
    private var identityPill: some View {
        switch model.state {
        case .library:
            ChromeTextLabel(text: "billiejean")
                .chromePill()
        case .player:
            HStack(spacing: WindowChrome.itemSpacing) {
                ChromeIconButton(symbol: "chevron.left", help: "Library  ⌘1") {
                    model.backToLibrary()
                }
                ChromeTextLabel(text: cap(model.currentPlaylistName))
            }
            .chromePill()
        }
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

    private func cap(_ s: String, _ maxLen: Int = 28) -> String {
        s.count <= maxLen ? s : String(s.prefix(maxLen - 1)) + "…"
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

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 28)]

    var body: some View {
        if model.musicNotRunning && model.playlists.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 34) {
                    ForEach(model.playlists) { playlist in
                        LibraryDiscCell(
                            playlist: playlist,
                            artwork: model.artworkImage(for: playlist.id),
                            dominant: model.dominantColor(for: playlist.id),
                            onAppear: { model.loadArtwork(for: playlist) },
                            onPlay: { model.play(playlist) }
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
            Text("Open Music to see your playlists as vinyl.")
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

// MARK: - Player canvas

@available(macOS 14.2, *)
struct PlayerCanvas: View {
    @Bindable var model: MainViewModel
    let canvasHeight: CGFloat

    private var studio: StudioViewModel { model.studio }

    private var recordSize: CGFloat { min(canvasHeight * 0.55, 420) }

    private var playlistID: String? {
        if case .player(let id) = model.state { return id }
        return nil
    }

    private var artwork: NSImage? {
        // Prefer live now-playing artwork, fall back to the playlist's disc art.
        studio.artworkImage ?? playlistID.flatMap { model.artworkImage(for: $0) }
    }

    private var dominant: Color? {
        studio.dominantColor ?? playlistID.flatMap { model.dominantColor(for: $0) }
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: WindowChrome.pillHeight + WindowChrome.edgeInset)

            PlayerRecord(
                diameter: recordSize,
                artwork: artwork,
                dominant: dominant,
                spinning: studio.isSpinning,
                engaged: studio.isRunning,
                cold: studio.bypass
            )

            trackInfo

            Spacer(minLength: WindowChrome.panelBottomClearance + WindowChrome.edgeInset)
        }
        .frame(maxWidth: .infinity)
    }

    private var trackInfo: some View {
        let snap = studio.snapshot
        return VStack(spacing: 4) {
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
        }
        .frame(maxWidth: 420)
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
}
