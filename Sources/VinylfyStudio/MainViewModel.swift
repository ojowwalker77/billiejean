import Foundation
import SwiftUI
import AppKit
import NowPlaying

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

    // MARK: - Flow

    private(set) var state: CanvasState = .library

    // MARK: - Library

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

    func artworkImage(for id: String) -> NSImage? { artwork[id] }
    func dominantColor(for id: String) -> Color? { dominant[id] }

    // MARK: - Lazy track artwork

    func loadTrackArtwork(_ track: MusicTrack, inPlaylist playlistID: String) {
        let id = track.id
        guard trackArtworkCache.object(forKey: id as NSString) == nil,
              !trackArtworkInFlight.contains(id) else { return }
        trackArtworkInFlight.insert(id)
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
        music.playPlaylist(id: playlist.id, shuffle: false)
        withAnimation(ChromeMotion.spring) {
            state = .player(playlistID: playlist.id)
        }
    }

    /// Play a single track within a playlist and transition to PLAYER.
    func playTrack(_ track: MusicTrack, inPlaylist playlistID: String) {
        music.playTrack(id: track.id, inPlaylist: playlistID)
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

    func playPause() { music.playPause() }
    func nextTrack() { music.nextTrack() }
    func previousTrack() { music.previousTrack() }
    func seek(toSeconds seconds: Double) { music.seek(toSeconds: seconds) }

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
