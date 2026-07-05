import Foundation
import SwiftUI
import AppKit
import NowPlaying
import PlayerBridge

/// The canvas has three states: a wall of playlist sleeves (LIBRARY), a wall of
/// track sleeves for one playlist (SONG GRID), and one big turntable (PLAYER).
enum CanvasState: Equatable {
    case library
    case songGrid(playlistID: String)
    case player(playlistID: String)
}

/// Owns the main-window flow (library ↔ player), the playlist wall, and lazy
/// per-playlist artwork. Shares the existing ``StudioViewModel`` singleton for
/// engine / now-playing / macros — this model never duplicates that state.
@available(macOS 14.2, *)
@MainActor
@Observable
final class MainViewModel {
    let studio = StudioViewModel.shared
    private let music = MusicController()
    /// The MusicKit helper bridge. While connected the app is fully
    /// standalone: transport, library, and now-playing all flow through it and
    /// Music.app is never consulted or launched.
    let standalone = StandalonePlayer()

    private var isStandalone: Bool { standalone.isConnected }

    init() {
        wireFlowControl()
        wireStandalone()
    }

    private func wireStandalone() {
        standalone.snapshotHandler = { [weak self] snap in
            self?.studio.ingestStandaloneSnapshot(snap)
        }
        standalone.commandFailureHandler = { [weak self] label in
            self?.showToast(symbol: "exclamationmark.triangle", message: "Player command failed (\(label))")
        }
        standalone.connectionHandler = { [weak self] connected in
            guard let self else { return }
            self.studio.activateStandalone(connected, helperBundleID: StandalonePlayer.helperBundleID)
            if connected {
                // A fresh engine has no banked lead: clear any hold a previous
                // app instance left on the helper (belt to the helper's own
                // last-client-disconnect suspenders).
                self.standalone.releaseSource()
            }
            // Refresh the wall from whichever library source is now live.
            self.refreshPlaylists()
        }
    }

    /// Flow control's source pause/resume: the helper bridge when standalone,
    /// the AppleScript transport otherwise. On release: never auto-resume over
    /// a user-held output — that would audibly restart the source while the
    /// user asked for silence.
    private func wireFlowControl() {
        studio.flowHoldHandler = { [weak self] holding in
            guard let self else { return }
            if holding {
                self.isStandalone ? self.standalone.holdSource() : self.music.pause()
            } else if !self.studio.userHeldOutput {
                self.isStandalone ? self.standalone.releaseSource() : self.music.resume()
            }
        }
    }

    // MARK: - Flow

    private(set) var state: CanvasState = .library

    // MARK: - Library

    /// What the sleeve wall shows. Albums exist only on the standalone bridge;
    /// they ride the whole playlist pipeline as `album:`-prefixed ids.
    enum LibraryScope: String {
        case playlists
        case albums
    }

    var libraryScope: LibraryScope = .playlists {
        didSet {
            guard oldValue != libraryScope else { return }
            playlists = []
            refreshPlaylists()
        }
    }

    private static let albumIDPrefix = "album:"

    /// The bare MusicKit album id when this wall id is an album, else nil.
    private static func albumID(_ id: String) -> String? {
        id.hasPrefix(albumIDPrefix) ? String(id.dropFirst(albumIDPrefix.count)) : nil
    }

    private(set) var playlists: [MusicPlaylist] = []
    private(set) var isLoadingPlaylists = false
    private(set) var musicNotRunning = false

    /// Per-playlist artwork, fetched lazily as discs appear.
    private(set) var artwork: [String: NSImage] = [:]
    /// Per-playlist dominant color, cached alongside artwork.
    private(set) var dominant: [String: Color] = [:]
    /// Playlists whose artwork fetch is in flight (avoid duplicate requests).
    private var artworkInFlight: Set<String> = []

    // MARK: - Song grid (tracks of one playlist)

    /// Tracks per playlist id, replaced whenever a song grid opens.
    private(set) var tracks: [String: [MusicTrack]] = [:]
    /// Playlists whose track fetch is in flight.
    private var tracksInFlight: Set<String> = []
    /// The last playlist whose song grid was shown — the player's back path.
    private(set) var lastSongGridPlaylistID: String?

    /// Per-track artwork + dominant color, keyed by track id.
    /// Decoded track covers, bounded (large playlists must not pin bitmaps).
    @ObservationIgnored private let trackArtworkCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 150
        return cache
    }()
    /// Bumped when a track cover lands so grid cells re-render.
    private(set) var trackArtworkVersion = 0
    private(set) var trackDominant: [String: Color] = [:]
    private var trackArtworkInFlight: Set<String> = []

    // MARK: - Transient error toast

    private(set) var toast: (symbol: String, message: String)?
    private var toastDismissWork: DispatchWorkItem?

    // MARK: - Derived

    /// The playlist id bound to the current non-library state (songGrid or player).
    var currentPlaylistID: String? {
        switch state {
        case .library: return nil
        case .songGrid(let id), .player(let id): return id
        }
    }

    /// The playlist bound to the current non-library state, if resolvable.
    var currentPlaylist: MusicPlaylist? {
        guard let id = currentPlaylistID else { return nil }
        return playlists.first { $0.id == id }
    }

    var currentPlaylistName: String {
        currentPlaylist?.name ?? "Now Playing"
    }

    /// Tracks for the current song grid (empty until fetched).
    func tracks(for id: String) -> [MusicTrack] { tracks[id] ?? [] }

    // MARK: - Library loading

    func loadPlaylistsIfNeeded() {
        guard playlists.isEmpty, !isLoadingPlaylists else { return }
        refreshPlaylists()
    }

    func refreshPlaylists() {
        isLoadingPlaylists = true
        if isStandalone {
            let scope = libraryScope
            Task { [weak self] in
                guard let self else { return }
                let lists: [MusicPlaylist]?
                switch scope {
                case .playlists:
                    lists = await self.standalone.fetchPlaylists()
                case .albums:
                    lists = (await self.standalone.fetchAlbums()).map { albums in
                        albums.map {
                            MusicPlaylist(
                                id: Self.albumIDPrefix + $0.id,
                                name: $0.title,
                                trackCount: $0.trackCount,
                                durationSeconds: nil
                            )
                        }
                    }
                }
                guard scope == self.libraryScope else { return }
                self.isLoadingPlaylists = false
                self.playlists = lists ?? []
                self.musicNotRunning = false
                if lists == nil {
                    self.showToast(symbol: "exclamationmark.triangle", message: "Couldn't load library")
                }
            }
            return
        }
        music.fetchPlaylists { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingPlaylists = false
                switch result {
                case .success(let lists):
                    self.playlists = lists
                    self.musicNotRunning = lists.isEmpty && !self.music.isMusicRunning
                case .failure:
                    self.playlists = []
                    self.musicNotRunning = !self.music.isMusicRunning
                    self.showToast(symbol: "exclamationmark.triangle", message: "Couldn't load playlists")
                }
            }
        }
    }

    /// Launch Music, then refetch after a short delay so playlists populate.
    func openMusic() {
        music.launchMusicIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshPlaylists()
        }
    }

    // MARK: - Lazy artwork

    /// Decode + downsample OFF the main thread. Apple Music covers arrive at up
    /// to ~3000px; a bare NSImage(data:) defers PNG decompression to first draw
    /// ON the main thread (profiled as scroll/hover jank). CGImageSource
    /// thumbnailing decodes once, small, in the background.
    nonisolated private static func decodedThumbnail(from data: Data, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
    }

    func loadArtwork(for playlist: MusicPlaylist) {
        let id = playlist.id
        guard artwork[id] == nil, !artworkInFlight.contains(id) else { return }
        artworkInFlight.insert(id)
        if isStandalone {
            Task { [weak self] in
                guard let self else { return }
                let data = await self.standalone.artworkData(forPlaylist: id)
                self.ingestPlaylistArtwork(id: id, data: data)
            }
            return
        }
        music.fetchArtwork(forPlaylist: id) { [weak self] data in
            guard let data else {
                Task { @MainActor in self?.artworkInFlight.remove(id) }
                return
            }
            Task.detached(priority: .utility) {
                let cg = Self.decodedThumbnail(from: data, maxPixel: 640)
                let rgb = ArtworkColor.dominant(from: data)
                await MainActor.run {
                    guard let self else { return }
                    self.artworkInFlight.remove(id)
                    if let cg {
                        self.artwork[id] = NSImage(cgImage: cg, size: .zero)
                    }
                    if let rgb {
                        self.dominant[id] = Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
                    }
                }
            }
        }
    }

    /// Shared tail of the playlist-artwork path: decode small off-main, then
    /// publish (used by both the AppleScript and standalone sources).
    private func ingestPlaylistArtwork(id: String, data: Data?) {
        guard let data else {
            artworkInFlight.remove(id)
            return
        }
        Task.detached(priority: .utility) {
            let cg = Self.decodedThumbnail(from: data, maxPixel: 640)
            let rgb = ArtworkColor.dominant(from: data)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.artworkInFlight.remove(id)
                if let cg {
                    self.artwork[id] = NSImage(cgImage: cg, size: .zero)
                }
                if let rgb {
                    self.dominant[id] = Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
                }
            }
        }
    }

    func artworkImage(for id: String) -> NSImage? { artwork[id] }
    func dominantColor(for id: String) -> Color? { dominant[id] }

    // MARK: - Lazy track artwork

    func loadTrackArtwork(_ track: MusicTrack, inPlaylist playlistID: String) {
        let id = track.id
        guard trackArtworkCache.object(forKey: id as NSString) == nil,
              !trackArtworkInFlight.contains(id) else { return }
        trackArtworkInFlight.insert(id)
        if isStandalone {
            Task { [weak self] in
                guard let self else { return }
                let data = await self.standalone.artworkData(forTrack: id)
                self.ingestTrackArtwork(id: id, data: data)
            }
            return
        }
        music.fetchArtwork(forTrack: id, inPlaylist: playlistID) { [weak self] data in
            guard let data else {
                Task { @MainActor in self?.trackArtworkInFlight.remove(id) }
                return
            }
            Task.detached(priority: .utility) {
                // Grid cells are ~170pt; 400px covers 2x displays.
                let cg = Self.decodedThumbnail(from: data, maxPixel: 400)
                let rgb = ArtworkColor.dominant(from: data)
                await MainActor.run {
                    guard let self else { return }
                    self.trackArtworkInFlight.remove(id)
                    if let cg {
                        self.trackArtworkCache.setObject(NSImage(cgImage: cg, size: .zero),
                                                         forKey: id as NSString)
                        self.trackArtworkVersion &+= 1
                    }
                    if let rgb {
                        self.trackDominant[id] = Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
                    }
                }
            }
        }
    }

    /// Shared tail of the track-artwork path (both sources).
    private func ingestTrackArtwork(id: String, data: Data?) {
        guard let data else {
            trackArtworkInFlight.remove(id)
            return
        }
        Task.detached(priority: .utility) {
            let cg = Self.decodedThumbnail(from: data, maxPixel: 400)
            let rgb = ArtworkColor.dominant(from: data)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.trackArtworkInFlight.remove(id)
                if let cg {
                    self.trackArtworkCache.setObject(NSImage(cgImage: cg, size: .zero),
                                                     forKey: id as NSString)
                    self.trackArtworkVersion &+= 1
                }
                if let rgb {
                    self.trackDominant[id] = Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
                }
            }
        }
    }

    func trackArtworkImage(for id: String) -> NSImage? {
        // Touch the observed version so cells re-render when images land; the
        // decoded images themselves live in a bounded NSCache (a 665-track
        // playlist must not pin hundreds of MB of bitmaps).
        _ = trackArtworkVersion
        return trackArtworkCache.object(forKey: id as NSString)
    }
    func trackDominantColor(for id: String) -> Color? { trackDominant[id] }

    // MARK: - Navigation flow

    /// Open a playlist's SONG GRID: transition, then fetch its tracks.
    func openSongGrid(_ playlist: MusicPlaylist) {
        let id = playlist.id
        lastSongGridPlaylistID = id
        withAnimation(ChromeMotion.spring) {
            state = .songGrid(playlistID: id)
        }
        fetchTracksIfNeeded(id)
    }

    private func fetchTracksIfNeeded(_ id: String) {
        guard tracks[id] == nil, !tracksInFlight.contains(id) else { return }
        tracksInFlight.insert(id)
        if isStandalone {
            Task { [weak self] in
                guard let self else { return }
                let list: [MusicTrack]?
                if let albumID = Self.albumID(id) {
                    list = await self.standalone.fetchAlbumTracks(albumId: albumID)
                } else {
                    list = await self.standalone.fetchTracks(forPlaylist: id)
                }
                self.tracksInFlight.remove(id)
                self.tracks[id] = list ?? []
                if list == nil {
                    self.showToast(symbol: "exclamationmark.triangle", message: "Couldn't load tracks")
                }
            }
            return
        }
        music.fetchTracks(forPlaylist: id) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.tracksInFlight.remove(id)
                switch result {
                case .success(let list):
                    self.tracks[id] = list
                case .failure:
                    self.tracks[id] = []
                    self.showToast(symbol: "exclamationmark.triangle", message: "Couldn't load tracks")
                }
            }
        }
    }

    // MARK: - Playback flow

    /// Play a whole playlist and transition to the PLAYER state.
    func play(_ playlist: MusicPlaylist) {
        studio.flushEffectPlayback()
        if isStandalone {
            if let albumID = Self.albumID(playlist.id) {
                standalone.playAlbum(id: albumID)
            } else {
                standalone.playPlaylist(id: playlist.id)
            }
        } else {
            music.playPlaylist(id: playlist.id, shuffle: false)
            confirmTransportSoon()
        }
        withAnimation(ChromeMotion.spring) {
            state = .player(playlistID: playlist.id)
        }
    }

    /// Play a single track within a playlist and transition to PLAYER.
    func playTrack(_ track: MusicTrack, inPlaylist playlistID: String) {
        studio.flushEffectPlayback()
        if isStandalone {
            // Native queue start-at — no helper playlist hack needed.
            if let albumID = Self.albumID(playlistID) {
                standalone.playAlbum(id: albumID, startIndex: max(0, track.index - 1))
            } else {
                standalone.playTrack(index: track.index, inPlaylist: playlistID)
            }
        } else {
            music.playTrack(id: track.id, index: track.index, inPlaylist: playlistID)
            confirmTransportSoon()
        }
        withAnimation(ChromeMotion.spring) {
            state = .player(playlistID: playlistID)
        }
    }

    func backToLibrary() {
        withAnimation(ChromeMotion.spring) {
            state = .library
        }
    }

    /// Back from the player: to the current playlist's SONG GRID if we have one,
    /// else the library. Song grid backs to the library.
    func back() {
        switch state {
        case .library:
            break
        case .songGrid:
            backToLibrary()
        case .player(let id):
            let target = lastSongGridPlaylistID ?? id
            if let playlist = playlists.first(where: { $0.id == target }) {
                openSongGrid(playlist)
            } else {
                backToLibrary()
            }
        }
    }

    // MARK: - Transport (delegates to MusicController)

    func playPause() {
        // While flow-held the source is ALREADY paused (muted, draining into
        // our slowed queue) — toggle our own output instead of the source.
        if studio.flowHolding {
            studio.toggleOutputHold()
            return
        }
        // Flip the published state NOW (button glyph, disc spin, needle creep
        // all follow it); the gate holds until a poll/push confirms.
        studio.notePlayPause()
        if isStandalone {
            standalone.playPause()
        } else {
            music.playPause()
            confirmTransportSoon()
        }
    }

    func nextTrack() {
        studio.flushEffectPlayback()
        if isStandalone {
            standalone.next()
        } else {
            music.nextTrack()
            confirmTransportSoon()
        }
    }

    func previousTrack() {
        studio.flushEffectPlayback()
        if isStandalone {
            standalone.previous()
        } else {
            music.previousTrack()
            confirmTransportSoon()
        }
    }

    func seek(toSeconds seconds: Double) {
        // Arm the poll-race gate BEFORE dispatching: a stale poll must never
        // land between the command send and the optimistic position write.
        studio.noteSeek(toSeconds: seconds)
        studio.flushEffectPlayback()
        if isStandalone {
            standalone.seek(toSeconds: seconds)
        } else {
            music.seek(toSeconds: seconds)
        }
    }

    /// Two quick off-schedule polls after a transport command: the first
    /// catches fast state flips (~0.4s), the second catches slower track
    /// changes and the queue-playlist play (~1.2s) — instead of waiting out
    /// the regular 2s tick.
    private func confirmTransportSoon() {
        Task { [studio] in
            try? await Task.sleep(for: .milliseconds(400))
            studio.refreshNowPlaying()
            try? await Task.sleep(for: .milliseconds(800))
            studio.refreshNowPlaying()
        }
    }

    // MARK: - Catalog search (⌘K overlay)

    /// Play a search result: drop any banked slowed audio, hand the catalog id
    /// to the helper, and land on the PLAYER (mirrors `playTrack`). A search
    /// play has no source playlist; back() falls through to the library.
    func playSearchResult(_ song: CatalogSong) {
        studio.flushEffectPlayback()
        standalone.playSong(id: song.id)
        withAnimation(ChromeMotion.spring) {
            if case .player = state {} else {
                state = .player(playlistID: lastSongGridPlaylistID ?? "")
            }
        }
    }

    // MARK: - Up Next queue

    /// Jump the standalone queue to `entry`. Drop any banked slowed audio FIRST
    /// (a jump changes the source track), then hand the entry id to the helper.
    func jumpToQueueEntry(_ entry: PlayerQueueEntry) {
        studio.flushEffectPlayback()
        standalone.jumpToQueueEntry(id: entry.id)
    }

    // MARK: - Toast

    func showToast(symbol: String, message: String) {
        toastDismissWork?.cancel()
        withAnimation(ChromeMotion.spring) {
            toast = (symbol, message)
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(ChromeMotion.dismiss) { self?.toast = nil }
        }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }
}
