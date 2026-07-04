import AppKit
import Foundation
import NowPlaying
import PlayerBridge

/// Adapter between the MusicKit player helper (over the bridge socket) and the
/// app's existing surfaces. Translates pushed `PlayerState` into
/// `NowPlayingSnapshot` and the helper's library into the same
/// `MusicPlaylist`/`MusicTrack` shapes the AppleScript path produces, so the
/// whole UI works standalone without knowing which backend is live.
@available(macOS 14.2, *)
@MainActor
@Observable
final class StandalonePlayer {
    static let helperBundleID = "com.jow.billiejean.player"

    /// True while the bridge socket is up — the app runs standalone and
    /// Music.app is never consulted (or launched).
    private(set) var isConnected = false

    /// Fires on connect/disconnect so the owner can swap tap target + polling.
    var connectionHandler: ((Bool) -> Void)?
    /// Fires on every pushed state, already converted to a snapshot.
    var snapshotHandler: ((NowPlayingSnapshot) -> Void)?

    private let client = PlayerHelperClient()
    private var artworkCache: [String: Data] = [:]
    private var artworkInFlight: Set<String> = []
    private var lastState: PlayerState?

    init() {
        client.connectionStateHandler = { [weak self] connected in
            Task { @MainActor in
                guard let self, self.isConnected != connected else { return }
                self.isConnected = connected
                self.connectionHandler?(connected)
            }
        }
        client.stateHandler = { [weak self] state in
            Task { @MainActor in
                self?.ingest(state)
            }
        }
        launchHelper()
    }

    /// The helper ships next to the main app bundle (dist/ during development);
    /// `vinylfy.playerHelperPath` overrides for odd layouts.
    private func launchHelper() {
        let url: URL
        if let override = UserDefaults.standard.string(forKey: "vinylfy.playerHelperPath") {
            url = URL(fileURLWithPath: override)
        } else {
            url = Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("billiejean-player.app")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        PlayerHelperClient.launchHelperIfNeeded(bundleURL: url)
    }

    // MARK: - State → snapshot

    private func ingest(_ state: PlayerState) {
        lastState = state
        guard let title = state.title, let artist = state.artist else {
            return
        }
        // Extrapolate to "now": pushes arrive at 1Hz; the timestamp removes
        // the socket+decode latency from the position the clock anchors on.
        var position = state.positionSeconds
        if state.isPlaying {
            position += max(0, Date.now.timeIntervalSince1970 - state.positionTimestamp)
        }
        let snapshot = NowPlayingSnapshot(
            title: title,
            artist: artist,
            genre: nil,
            isPlaying: state.isPlaying || state.isSourceHeld,
            positionSeconds: position,
            durationSeconds: state.durationSeconds,
            artworkPNGData: state.artworkURL.flatMap { artworkCache[$0] },
            source: "billiejean"
        )
        snapshotHandler?(snapshot)

        // Artwork arrives as a URL; fetch once per URL, then re-push the
        // snapshot so the disc label fills in.
        if let urlString = state.artworkURL, artworkCache[urlString] == nil {
            fetchArtwork(urlString)
        }
    }

    private func fetchArtwork(_ urlString: String) {
        guard !artworkInFlight.contains(urlString), let url = URL(string: urlString) else { return }
        artworkInFlight.insert(urlString)
        Task { [weak self] in
            let data = try? await URLSession.shared.data(from: url).0
            await MainActor.run {
                guard let self else { return }
                self.artworkInFlight.remove(urlString)
                if let data {
                    self.artworkCache[urlString] = data
                    if let state = self.lastState, state.artworkURL == urlString {
                        self.ingest(state)
                    }
                }
            }
        }
    }

    // MARK: - Transport (fire-and-forget; state pushes confirm)

    /// Errors from a command must never vanish (a swallowed play failure looks
    /// exactly like "the button did nothing"). Logged + surfaced to the owner.
    var commandFailureHandler: ((String) -> Void)?

    private func send(_ label: String, _ op: @escaping () async throws -> Void) {
        Task { [weak self] in
            do {
                try await op()
            } catch {
                print("DIAG standalone \(label) failed: \(error)")
                await MainActor.run { self?.commandFailureHandler?(label) }
            }
        }
    }

    func play() { send("play") { [client] in try await client.play() } }
    func pause() { send("pause") { [client] in try await client.pause() } }
    func playPause() { send("playPause") { [client] in try await client.playPause() } }
    func next() { send("next") { [client] in try await client.next() } }
    func previous() { send("previous") { [client] in try await client.previous() } }
    func seek(toSeconds seconds: Double) { send("seek") { [client] in try await client.seek(seconds: seconds) } }
    func holdSource() { send("holdSource") { [client] in try await client.holdSource() } }
    func releaseSource() { send("releaseSource") { [client] in try await client.releaseSource() } }

    func playPlaylist(id: String) {
        send("playPlaylist") { [client] in try await client.playPlaylist(playlistId: id, startIndex: nil) }
    }

    func playTrack(index: Int, inPlaylist playlistID: String) {
        // Helper indices are 0-based queue offsets; MusicTrack.index is 1-based.
        send("playTrack") { [client] in
            try await client.playPlaylist(playlistId: playlistID, startIndex: max(0, index - 1))
        }
    }

    // MARK: - Queue (Up Next)

    func queueEntries() async -> [PlayerQueueEntry]? {
        (try? await client.queueEntries())?.entries
    }

    func jumpToQueueEntry(id: String) {
        send("queueJump") { [client] in try await client.jumpToQueueEntry(entryId: id) }
    }

    // MARK: - Albums

    func fetchAlbums() async -> [PlayerAlbum]? {
        guard let result = try? await client.albums() else { return nil }
        for album in result.albums {
            if let url = album.artworkURL { playlistArtworkURLs["album:\(album.id)"] = url }
        }
        return result.albums
    }

    func fetchAlbumTracks(albumId: String) async -> [MusicTrack]? {
        guard let result = try? await client.albumTracks(albumId: albumId) else { return nil }
        for t in result.tracks {
            if let url = t.artworkURL { trackArtworkURLs[t.id] = url }
        }
        return result.tracks.map {
            MusicTrack(id: $0.id, name: $0.title, artist: $0.artist,
                       durationSeconds: $0.durationSeconds, index: $0.index)
        }
    }

    func playAlbum(id: String, startIndex: Int? = nil) {
        send("playAlbum") { [client] in try await client.playAlbum(albumId: id, startIndex: startIndex) }
    }

    // MARK: - Catalog search

    func searchCatalog(term: String, limit: Int = 12) async -> [CatalogSong]? {
        (try? await client.search(term: term, limit: limit))?.songs
    }

    func playSong(id: String) {
        send("playSong") { [client] in try await client.playSearchResult(songId: id) }
    }

    // MARK: - Library (mapped to the AppleScript-era shapes)

    /// Artwork URLs remembered from the last library fetches, keyed by
    /// playlist/track id, so the lazy artwork loaders can resolve them.
    private var playlistArtworkURLs: [String: String] = [:]
    private var trackArtworkURLs: [String: String] = [:]

    func fetchPlaylists() async -> [MusicPlaylist]? {
        guard let result = try? await client.playlists() else { return nil }
        for p in result.playlists {
            if let url = p.artworkURL { playlistArtworkURLs[p.id] = url }
        }
        return result.playlists.map {
            MusicPlaylist(id: $0.id, name: $0.name, trackCount: $0.trackCount, durationSeconds: nil)
        }
    }

    func fetchTracks(forPlaylist id: String) async -> [MusicTrack]? {
        guard let result = try? await client.playlistTracks(playlistId: id) else { return nil }
        for t in result.tracks {
            if let url = t.artworkURL { trackArtworkURLs[t.id] = url }
        }
        return result.tracks.map {
            MusicTrack(id: $0.id, name: $0.title, artist: $0.artist,
                       durationSeconds: $0.durationSeconds, index: $0.index)
        }
    }

    func artworkData(forPlaylist id: String) async -> Data? {
        await artworkData(urlString: playlistArtworkURLs[id])
    }

    func artworkData(forTrack id: String) async -> Data? {
        await artworkData(urlString: trackArtworkURLs[id])
    }

    func artworkData(urlString: String?) async -> Data? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        if let cached = artworkCache[urlString] { return cached }
        guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
        artworkCache[urlString] = data
        return data
    }
}
