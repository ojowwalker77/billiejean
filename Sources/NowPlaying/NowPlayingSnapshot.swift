import Foundation

public struct NowPlayingSnapshot: Sendable, Equatable {
    public let title: String
    public let artist: String
    public let isPlaying: Bool
    public let positionSeconds: Double?
    public let durationSeconds: Double?
    public let artworkPNGData: Data?
    public let source: String
}
