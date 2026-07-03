import Foundation

public struct NowPlayingSnapshot: Sendable, Equatable {
    public let title: String
    public let artist: String
    public let genre: String?
    public let isPlaying: Bool
    public let positionSeconds: Double?
    public let durationSeconds: Double?
    public let artworkPNGData: Data?
    public let source: String

    public init(
        title: String,
        artist: String,
        genre: String? = nil,
        isPlaying: Bool,
        positionSeconds: Double?,
        durationSeconds: Double?,
        artworkPNGData: Data?,
        source: String
    ) {
        self.title = title
        self.artist = artist
        self.genre = genre
        self.isPlaying = isPlaying
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.artworkPNGData = artworkPNGData
        self.source = source
    }
}
