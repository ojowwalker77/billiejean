import AppKit
import Foundation

public final class NowPlayingService: @unchecked Sendable {
    private enum Source {
        case music
        case spotify
    }

    private struct TrackMetadata {
        let title: String
        let artist: String
        let isPlaying: Bool
        let positionSeconds: Double?
        let durationSeconds: Double?
        let source: Source
        let artworkURL: String?

        var trackKey: String {
            "\(title)\u{1f}\(artist)"
        }
    }

    private enum ScriptKind: CaseIterable {
        case musicMetadata
        case musicArtwork
        case spotifyMetadata

        var source: String {
            switch self {
            case .musicMetadata:
                """
                tell application id "com.apple.Music"
                    if player state is stopped then return missing value
                    set currentTrack to current track
                    set trackName to name of currentTrack
                    set trackArtist to artist of currentTrack
                    set trackPosition to player position
                    set trackDuration to duration of currentTrack
                    set trackPlaying to (player state is playing)
                    return {trackName as text, trackArtist as text, trackPlaying, trackPosition, trackDuration}
                end tell
                """
            case .musicArtwork:
                """
                tell application id "com.apple.Music"
                    if player state is stopped then return missing value
                    set currentTrack to current track
                    if (count of artworks of currentTrack) is 0 then return missing value
                    return raw data of artwork 1 of currentTrack
                end tell
                """
            case .spotifyMetadata:
                """
                tell application id "com.spotify.client"
                    if player state is stopped then return missing value
                    set currentTrack to current track
                    set trackName to name of currentTrack
                    set trackArtist to artist of currentTrack
                    set trackPosition to player position
                    set trackDuration to duration of currentTrack
                    set trackPlaying to (player state is playing)
                    set trackArtworkURL to artwork url of currentTrack
                    return {trackName as text, trackArtist as text, trackPlaying, trackPosition, trackDuration, trackArtworkURL as text}
                end tell
                """
            }
        }
    }

    private final class DownloadResult: @unchecked Sendable {
        private let lock = NSLock()
        private var _data: Data?

        var data: Data? {
            lock.lock()
            defer { lock.unlock() }
            return _data
        }

        func setData(_ data: Data?) {
            lock.lock()
            _data = data
            lock.unlock()
        }
    }

    private let pollInterval: TimeInterval
    private let pollQueue = DispatchQueue(label: "NowPlayingService.poll")
    private let handlerLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var _snapshotHandler: (@Sendable (NowPlayingSnapshot?) -> Void)?

    private var scripts: [ScriptKind: NSAppleScript] = [:]
    private var musicArtworkCache: [String: Data] = [:]
    private var missingMusicArtworkKeys: Set<String> = []
    private var spotifyArtworkCache: [String: Data] = [:]
    private var missingSpotifyArtworkURLs: Set<String> = []

    public init(pollInterval: TimeInterval = 2.0) {
        self.pollInterval = max(0.1, pollInterval)
    }

    deinit {
        stop()
    }

    public var snapshotHandler: (@Sendable (NowPlayingSnapshot?) -> Void)? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return _snapshotHandler
        }
        set {
            handlerLock.lock()
            _snapshotHandler = newValue
            handlerLock.unlock()
        }
    }

    public func start() {
        pollQueue.async { [weak self] in
            guard let self, self.timer == nil else { return }

            let timer = DispatchSource.makeTimerSource(queue: self.pollQueue)
            timer.schedule(deadline: .now(), repeating: self.pollInterval)
            timer.setEventHandler { [weak self] in
                self?.poll()
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        pollQueue.async { [weak self] in
            guard let self, let timer = self.timer else { return }
            timer.setEventHandler {}
            timer.cancel()
            self.timer = nil
        }
    }

    private func poll() {
        let snapshot = makeSnapshot()
        snapshotHandler?(snapshot)
    }

    private func makeSnapshot() -> NowPlayingSnapshot? {
        if isApplicationRunning(bundleIdentifier: "com.apple.Music"),
           let metadata = executeMetadataScript(.musicMetadata),
           let snapshot = snapshot(from: metadata) {
            return snapshot
        }

        if isApplicationRunning(bundleIdentifier: "com.spotify.client"),
           let metadata = executeMetadataScript(.spotifyMetadata),
           let snapshot = snapshot(from: metadata) {
            return snapshot
        }

        return nil
    }

    private func snapshot(from metadata: TrackMetadata) -> NowPlayingSnapshot? {
        let artworkData: Data?

        switch metadata.source {
        case .music:
            artworkData = musicArtwork(for: metadata)
        case .spotify:
            artworkData = spotifyArtwork(for: metadata)
        }

        return NowPlayingSnapshot(
            title: metadata.title,
            artist: metadata.artist,
            isPlaying: metadata.isPlaying,
            positionSeconds: metadata.positionSeconds,
            durationSeconds: metadata.durationSeconds,
            artworkPNGData: artworkData,
            source: metadata.source == .music ? "Music" : "Spotify"
        )
    }

    private func executeMetadataScript(_ kind: ScriptKind) -> TrackMetadata? {
        guard let descriptor = executeScript(kind), descriptor.numberOfItems >= 5 else {
            return nil
        }

        guard let title = descriptor.atIndex(1)?.stringValue?.nilIfEmpty,
              let artist = descriptor.atIndex(2)?.stringValue?.nilIfEmpty else {
            return nil
        }

        let isPlaying = descriptor.atIndex(3)?.booleanValue ?? false
        let positionSeconds = descriptor.atIndex(4)?.optionalDouble
        var durationSeconds = descriptor.atIndex(5)?.optionalDouble

        switch kind {
        case .musicMetadata:
            return TrackMetadata(
                title: title,
                artist: artist,
                isPlaying: isPlaying,
                positionSeconds: positionSeconds,
                durationSeconds: durationSeconds,
                source: .music,
                artworkURL: nil
            )
        case .spotifyMetadata:
            if let duration = durationSeconds, duration > 10_000 {
                durationSeconds = duration / 1_000
            }

            return TrackMetadata(
                title: title,
                artist: artist,
                isPlaying: isPlaying,
                positionSeconds: positionSeconds,
                durationSeconds: durationSeconds,
                source: .spotify,
                artworkURL: descriptor.atIndex(6)?.stringValue?.nilIfEmpty
            )
        case .musicArtwork:
            return nil
        }
    }

    private func musicArtwork(for metadata: TrackMetadata) -> Data? {
        let key = metadata.trackKey

        if let cached = musicArtworkCache[key] {
            return cached
        }

        if missingMusicArtworkKeys.contains(key) {
            return nil
        }

        guard isApplicationRunning(bundleIdentifier: "com.apple.Music"),
              let descriptor = executeScript(.musicArtwork),
              let pngData = Self.pngData(from: descriptor.data) else {
            missingMusicArtworkKeys.insert(key)
            return nil
        }

        missingMusicArtworkKeys.remove(key)
        musicArtworkCache[key] = pngData
        return pngData
    }

    private func spotifyArtwork(for metadata: TrackMetadata) -> Data? {
        guard let artworkURL = metadata.artworkURL else {
            return nil
        }

        if let cached = spotifyArtworkCache[artworkURL] {
            return cached
        }

        if missingSpotifyArtworkURLs.contains(artworkURL) {
            return nil
        }

        guard let url = URL(string: artworkURL),
              let imageData = downloadArtwork(from: url),
              let pngData = Self.pngData(from: imageData) else {
            missingSpotifyArtworkURLs.insert(artworkURL)
            return nil
        }

        missingSpotifyArtworkURLs.remove(artworkURL)
        spotifyArtworkCache[artworkURL] = pngData
        return pngData
    }

    private func downloadArtwork(from url: URL) -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3

        let session = URLSession(configuration: configuration)
        let semaphore = DispatchSemaphore(value: 0)
        let result = DownloadResult()

        let task = session.dataTask(with: url) { data, response, _ in
            defer { semaphore.signal() }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return
            }

            result.setData(data)
        }

        task.resume()
        _ = semaphore.wait(timeout: .now() + 3.25)
        task.cancel()
        session.invalidateAndCancel()

        return result.data
    }

    private func executeScript(_ kind: ScriptKind) -> NSAppleEventDescriptor? {
        runOnMain {
            guard let script = self.compiledScript(kind) else {
                return nil
            }

            var error: NSDictionary?
            let descriptor = script.executeAndReturnError(&error)
            guard error == nil else {
                return nil
            }

            return descriptor
        }
    }

    private func compiledScript(_ kind: ScriptKind) -> NSAppleScript? {
        if let script = scripts[kind] {
            return script
        }

        guard let script = NSAppleScript(source: kind.source) else {
            return nil
        }

        var error: NSDictionary?
        guard script.compileAndReturnError(&error), error == nil else {
            return nil
        }

        scripts[kind] = script
        return script
    }

    private func runOnMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }

        return DispatchQueue.main.sync(execute: work)
    }

    private func isApplicationRunning(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            application.bundleIdentifier == bundleIdentifier && !application.isTerminated
        }
    }

    private static func pngData(from imageData: Data) -> Data? {
        guard !imageData.isEmpty else {
            return nil
        }

        guard let image = NSImage(data: imageData),
              let tiffData = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return representation.representation(using: .png, properties: [:])
    }
}

private extension NSAppleEventDescriptor {
    var optionalDouble: Double? {
        guard descriptorType != typeNull else {
            return nil
        }

        if let value = stringValue.flatMap(Double.init) {
            return value
        }

        let value = doubleValue
        return value.isFinite ? value : nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
