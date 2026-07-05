import Foundation

public struct EmptyParams: Codable, Equatable, Sendable {
    public init() {}
}

public struct OKResult: Codable, Equatable, Sendable {
    public let ok: Bool

    public init(ok: Bool = true) {
        self.ok = ok
    }
}

public struct SeekParams: Codable, Equatable, Sendable {
    public let seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }
}

public struct PlayPlaylistParams: Codable, Equatable, Sendable {
    public let playlistId: String
    public let startIndex: Int?

    public init(playlistId: String, startIndex: Int? = nil) {
        self.playlistId = playlistId
        self.startIndex = startIndex
    }
}

public struct PlayAlbumParams: Codable, Equatable, Sendable {
    public let albumId: String
    public let startIndex: Int?

    public init(albumId: String, startIndex: Int? = nil) {
        self.albumId = albumId
        self.startIndex = startIndex
    }
}

public enum TrackListContainerKind: String, Codable, Equatable, Sendable {
    case playlist
    case album
}

public struct PlayTrackListParams: Codable, Equatable, Sendable {
    public let containerId: String
    public let containerKind: TrackListContainerKind
    public let trackIds: [String]
    public let startIndex: Int

    public init(
        containerId: String,
        containerKind: TrackListContainerKind,
        trackIds: [String],
        startIndex: Int
    ) {
        self.containerId = containerId
        self.containerKind = containerKind
        self.trackIds = trackIds
        self.startIndex = startIndex
    }
}

public struct PlaySearchResultParams: Codable, Equatable, Sendable {
    public let songId: String

    public init(songId: String) {
        self.songId = songId
    }
}

public struct QueueJumpParams: Codable, Equatable, Sendable {
    public let entryId: String

    public init(entryId: String) {
        self.entryId = entryId
    }
}

public struct PlaylistTracksParams: Codable, Equatable, Sendable {
    public let playlistId: String

    public init(playlistId: String) {
        self.playlistId = playlistId
    }
}

public struct AlbumTracksParams: Codable, Equatable, Sendable {
    public let albumId: String

    public init(albumId: String) {
        self.albumId = albumId
    }
}

public struct SearchParams: Codable, Equatable, Sendable {
    public let term: String
    public let limit: Int

    public init(term: String, limit: Int) {
        self.term = term
        self.limit = limit
    }
}

public struct PlayerPlaylist: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let trackCount: Int
    public let artworkURL: String?

    public init(id: String, name: String, trackCount: Int, artworkURL: String? = nil) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.artworkURL = artworkURL
    }
}

public struct PlayerAlbum: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let artist: String
    public let trackCount: Int
    public let artworkURL: String?

    public init(id: String, title: String, artist: String, trackCount: Int, artworkURL: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.trackCount = trackCount
        self.artworkURL = artworkURL
    }
}

public struct PlayerTrack: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let artist: String
    public let durationSeconds: Double?
    public let artworkURL: String?
    public let index: Int

    public init(
        id: String,
        title: String,
        artist: String,
        durationSeconds: Double?,
        artworkURL: String? = nil,
        index: Int
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.durationSeconds = durationSeconds
        self.artworkURL = artworkURL
        self.index = index
    }
}

public struct PlayerQueueEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let artist: String
    public let durationSeconds: Double?
    public let artworkURL: String?
    public let isCurrent: Bool

    public init(
        id: String,
        title: String,
        artist: String,
        durationSeconds: Double?,
        artworkURL: String? = nil,
        isCurrent: Bool
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.durationSeconds = durationSeconds
        self.artworkURL = artworkURL
        self.isCurrent = isCurrent
    }
}

public struct CatalogSong: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let artist: String
    public let albumTitle: String
    public let durationSeconds: Double?
    public let artworkURL: String?

    public init(
        id: String,
        title: String,
        artist: String,
        albumTitle: String,
        durationSeconds: Double?,
        artworkURL: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.durationSeconds = durationSeconds
        self.artworkURL = artworkURL
    }
}

public struct QueueEntriesResult: Codable, Equatable, Sendable {
    public let entries: [PlayerQueueEntry]

    public init(entries: [PlayerQueueEntry]) {
        self.entries = entries
    }
}

public struct PlaylistsResult: Codable, Equatable, Sendable {
    public let playlists: [PlayerPlaylist]

    public init(playlists: [PlayerPlaylist]) {
        self.playlists = playlists
    }
}

public struct AlbumsResult: Codable, Equatable, Sendable {
    public let albums: [PlayerAlbum]

    public init(albums: [PlayerAlbum]) {
        self.albums = albums
    }
}

public struct PlaylistTracksResult: Codable, Equatable, Sendable {
    public let tracks: [PlayerTrack]

    public init(tracks: [PlayerTrack]) {
        self.tracks = tracks
    }
}

public struct CatalogSearchResult: Codable, Equatable, Sendable {
    public let songs: [CatalogSong]

    public init(songs: [CatalogSong]) {
        self.songs = songs
    }
}

public struct PlayerState: Codable, Equatable, Sendable {
    public let isPlaying: Bool
    public let isSourceHeld: Bool
    public let title: String?
    public let artist: String?
    public let durationSeconds: Double?
    public let positionSeconds: Double
    public let positionTimestamp: Double
    public let artworkURL: String?
    public let queueIndex: Int?
    public let queueCount: Int?

    public init(
        isPlaying: Bool,
        isSourceHeld: Bool,
        title: String?,
        artist: String?,
        durationSeconds: Double?,
        positionSeconds: Double,
        positionTimestamp: Double,
        artworkURL: String?,
        queueIndex: Int?,
        queueCount: Int?
    ) {
        self.isPlaying = isPlaying
        self.isSourceHeld = isSourceHeld
        self.title = title
        self.artist = artist
        self.durationSeconds = durationSeconds
        self.positionSeconds = positionSeconds
        self.positionTimestamp = positionTimestamp
        self.artworkURL = artworkURL
        self.queueIndex = queueIndex
        self.queueCount = queueCount
    }
}
