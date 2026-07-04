import Foundation
import MusicKit
import PlayerBridge

@available(macOS 15.0, *)
@MainActor
final class PlayerCore {
    nonisolated(unsafe) private let player = ApplicationMusicPlayer.shared
    var stateDidChange: (@Sendable (PlayerState) -> Void)?

    private var pollingTask: Task<Void, Never>?
    private var isSourceHeld = false
    private var intendedPlayback = false
    private var lastSignature: StateSignature?
    private var lastOneSecondPush = Date.distantPast

    func startObservation() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let state = self.currentState()
                let signature = StateSignature(state)
                let shouldPushPeriodic = state.isPlaying && Date().timeIntervalSince(self.lastOneSecondPush) >= 1.0

                if signature != self.lastSignature || shouldPushPeriodic {
                    self.publish(state)
                    if state.isPlaying {
                        self.lastOneSecondPush = Date()
                    }
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        publish(currentState())
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        player.stop()
    }

    func play() async throws {
        intendedPlayback = true
        guard !isSourceHeld else {
            publish(currentState())
            return
        }
        try await player.play()
        publish(currentState())
    }

    func pause() {
        intendedPlayback = false
        player.pause()
        publish(currentState())
    }

    func playPause() async throws {
        if intendedPlayback || player.state.playbackStatus == .playing {
            pause()
        } else {
            try await play()
        }
    }

    func next() async throws {
        try await player.skipToNextEntry()
        publish(currentState())
    }

    func previous() async throws {
        try await player.skipToPreviousEntry()
        publish(currentState())
    }

    func seek(seconds: Double) {
        player.playbackTime = max(0, seconds)
        publish(currentState())
    }

    func holdSource() {
        guard !isSourceHeld else {
            publish(currentState())
            return
        }
        intendedPlayback = player.state.playbackStatus == .playing || intendedPlayback
        isSourceHeld = true
        player.pause()
        publish(currentState())
    }

    func releaseSource() async throws {
        guard isSourceHeld else {
            publish(currentState())
            return
        }
        isSourceHeld = false
        if intendedPlayback {
            try await player.play()
        }
        publish(currentState())
    }

    func queueEntries() -> QueueEntriesResult {
        let currentEntry = player.queue.currentEntry
        let currentID = currentEntry.map(queueEntryID)

        return QueueEntriesResult(
            entries: player.queue.entries.map { entry in
                let entryID = queueEntryID(entry)
                return PlayerQueueEntry(
                    id: entryID,
                    title: entry.title,
                    artist: entry.subtitle ?? "",
                    durationSeconds: durationSeconds(for: entry),
                    artworkURL: artworkURL(entry.artwork),
                    isCurrent: entryID == currentID
                )
            }
        )
    }

    func jumpToQueueEntry(entryId: String) async throws {
        guard let entry = player.queue.entries.first(where: { queueEntryID($0) == entryId }) else {
            throw PlayerCoreError.notFound("Queue entry not found: \(entryId)")
        }

        player.queue.currentEntry = entry
        intendedPlayback = true

        if !isSourceHeld {
            try await player.play()
        }
        publish(currentState())
    }

    func playAlbum(albumId: String, startIndex: Int?) async throws {
        let album = try await libraryAlbum(id: albumId).with(.tracks)
        let tracks = Array(album.tracks ?? [])
        guard !tracks.isEmpty else {
            throw PlayerCoreError.notFound("Album has no playable tracks: \(albumId)")
        }

        let boundedIndex = min(max(startIndex ?? 0, 0), tracks.count - 1)
        let startTrack = tracks[boundedIndex]
        player.queue = ApplicationMusicPlayer.Queue(for: tracks, startingAt: startTrack)
        intendedPlayback = true

        if !isSourceHeld {
            try await player.play()
        }
        publish(currentState())
    }

    func playPlaylist(playlistId: String, startIndex: Int?) async throws {
        let playlist = try await libraryPlaylist(id: playlistId).with(.tracks)
        let tracks = Array(playlist.tracks ?? [])
        guard !tracks.isEmpty else {
            throw PlayerCoreError.notFound("Playlist has no playable tracks: \(playlistId)")
        }

        let boundedIndex = min(max(startIndex ?? 0, 0), tracks.count - 1)
        let startTrack = tracks[boundedIndex]
        player.queue = ApplicationMusicPlayer.Queue(for: tracks, startingAt: startTrack)
        intendedPlayback = true

        if !isSourceHeld {
            try await player.play()
        }
        publish(currentState())
    }

    func playSearchResult(songId: String) async throws {
        let song = try await catalogSong(id: songId)
        player.queue = ApplicationMusicPlayer.Queue(for: [song], startingAt: song)
        intendedPlayback = true

        if !isSourceHeld {
            try await player.play()
        }
        publish(currentState())
    }

    func albums() async throws -> AlbumsResult {
        var request = MusicLibraryRequest<Album>()
        request.limit = 100
        let response = try await request.response()
        var albums: [PlayerAlbum] = []

        for album in response.items.sorted(by: { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }) {
            let hydrated = (try? await album.with(.tracks)) ?? album
            albums.append(PlayerAlbum(
                id: hydrated.id.rawValue,
                title: hydrated.title,
                artist: hydrated.artistName,
                trackCount: hydrated.tracks?.count ?? 0,
                artworkURL: artworkURL(hydrated.artwork)
            ))
        }
        return AlbumsResult(albums: albums)
    }

    func playlists() async throws -> PlaylistsResult {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = 100
        let response = try await request.response()
        var playlists: [PlayerPlaylist] = []

        for playlist in response.items {
            let hydrated = (try? await playlist.with(.tracks)) ?? playlist
            playlists.append(PlayerPlaylist(
                id: hydrated.id.rawValue,
                name: hydrated.name,
                trackCount: hydrated.tracks?.count ?? 0,
                artworkURL: artworkURL(hydrated.artwork)
            ))
        }
        return PlaylistsResult(playlists: playlists)
    }

    func playlistTracks(playlistId: String) async throws -> PlaylistTracksResult {
        let playlist = try await libraryPlaylist(id: playlistId).with(.tracks)
        let tracks = Array(playlist.tracks ?? [])
        return PlaylistTracksResult(tracks: playerTracks(from: tracks))
    }

    func albumTracks(albumId: String) async throws -> PlaylistTracksResult {
        let album = try await libraryAlbum(id: albumId).with(.tracks)
        let tracks = Array(album.tracks ?? [])
        return PlaylistTracksResult(tracks: playerTracks(from: tracks))
    }

    func searchFirstSong(term: String, limit: Int) async throws -> CatalogSearchResult {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = max(1, limit)
        let response = try await request.response()
        return CatalogSearchResult(
            songs: response.songs.map {
                CatalogSong(
                    id: $0.id.rawValue,
                    title: $0.title,
                    artist: $0.artistName,
                    albumTitle: $0.albumTitle ?? "",
                    durationSeconds: $0.duration,
                    artworkURL: artworkURL($0.artwork)
                )
            }
        )
    }

    func currentState() -> PlayerState {
        let entry = player.queue.currentEntry
        let entries = Array(player.queue.entries)
        let queueIndex = entry.flatMap { current in
            entries.firstIndex { $0.id == current.id }
        }

        return PlayerState(
            isPlaying: player.state.playbackStatus == .playing,
            isSourceHeld: isSourceHeld,
            title: entry?.title,
            artist: entry?.subtitle,
            durationSeconds: durationSeconds(for: entry),
            positionSeconds: max(0, player.playbackTime),
            positionTimestamp: Date().timeIntervalSince1970,
            artworkURL: artworkURL(entry?.artwork),
            queueIndex: queueIndex,
            queueCount: entries.isEmpty ? nil : entries.count
        )
    }

    private func libraryPlaylist(id: String) async throws -> Playlist {
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        request.limit = 1

        guard let playlist = try await request.response().items.first else {
            throw PlayerCoreError.notFound("Playlist not found: \(id)")
        }
        return playlist
    }

    private func libraryAlbum(id: String) async throws -> Album {
        var request = MusicLibraryRequest<Album>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        request.limit = 1

        guard let album = try await request.response().items.first else {
            throw PlayerCoreError.notFound("Album not found: \(id)")
        }
        return album
    }

    private func catalogSong(id: String) async throws -> Song {
        var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        request.limit = 1

        guard let song = try await request.response().items.first else {
            throw PlayerCoreError.notFound("Song not found: \(id)")
        }
        return song
    }

    private func publish(_ state: PlayerState) {
        lastSignature = StateSignature(state)
        stateDidChange?(state)
    }

    private func playerTracks(from tracks: [Track]) -> [PlayerTrack] {
        tracks.enumerated().map { index, track in
            PlayerTrack(
                id: track.id.rawValue,
                title: track.title,
                artist: track.artistName,
                durationSeconds: track.duration,
                artworkURL: artworkURL(track.artwork),
                index: index
            )
        }
    }

    private func queueEntryID(_ entry: MusicPlayer.Queue.Entry) -> String {
        String(describing: entry.id)
    }

    private func durationSeconds(for entry: MusicPlayer.Queue.Entry?) -> Double? {
        guard let entry else {
            return nil
        }

        switch entry.item {
        case .song(let song):
            return song.duration
        case .musicVideo(let video):
            return video.duration
        case nil:
            if let song = entry.transientItem as? Song {
                return song.duration
            }
            if let track = entry.transientItem as? Track {
                return track.duration
            }
            return nil
        @unknown default:
            return nil
        }
    }

    private func artworkURL(_ artwork: Artwork?) -> String? {
        artwork?.url(width: 600, height: 600)?.absoluteString
    }
}

@available(macOS 15.0, *)
private struct StateSignature: Equatable {
    let isPlaying: Bool
    let isSourceHeld: Bool
    let title: String?
    let artist: String?
    let durationSeconds: Double?
    let artworkURL: String?
    let queueIndex: Int?
    let queueCount: Int?

    init(_ state: PlayerState) {
        isPlaying = state.isPlaying
        isSourceHeld = state.isSourceHeld
        title = state.title
        artist = state.artist
        durationSeconds = state.durationSeconds
        artworkURL = state.artworkURL
        queueIndex = state.queueIndex
        queueCount = state.queueCount
    }
}

@available(macOS 15.0, *)
private enum PlayerCoreError: LocalizedError {
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let message):
            message
        }
    }
}
