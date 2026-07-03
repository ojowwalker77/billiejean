import AppKit
import Carbon
import Foundation
import OSLog

public struct MusicPlaylist: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let trackCount: Int
    public let durationSeconds: Double?
    public var artworkPNGData: Data?

    public init(
        id: String,
        name: String,
        trackCount: Int,
        durationSeconds: Double?,
        artworkPNGData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.durationSeconds = durationSeconds
        self.artworkPNGData = artworkPNGData
    }
}

public final class MusicController: @unchecked Sendable {
    private enum ScriptKind: CaseIterable {
        case fetchPlaylists
        case fetchArtwork
        case playPlaylist
        case playPause
        case nextTrack
        case previousTrack
        case seek
        case setShuffle

        var source: String {
            switch self {
            case .fetchPlaylists:
                """
                on run
                    set recordDelimiter to ASCII character 30
                    set unitDelimiter to ASCII character 31
                    set rows to {}
                    tell application id "com.apple.Music"
                        repeat with aPlaylist in (every user playlist whose special kind is none)
                            set playlistID to persistent ID of aPlaylist as text
                            set playlistName to name of aPlaylist as text
                            set playlistTrackCount to count of tracks of aPlaylist
                            try
                                set playlistDuration to duration of aPlaylist
                            on error
                                set playlistDuration to missing value
                            end try
                            if playlistDuration is missing value then
                                set durationText to ""
                            else
                                set durationText to playlistDuration as text
                            end if
                            set end of rows to playlistID & unitDelimiter & playlistName & unitDelimiter & (playlistTrackCount as text) & unitDelimiter & durationText
                        end repeat
                    end tell
                    set AppleScript's text item delimiters to recordDelimiter
                    set outputText to rows as text
                    set AppleScript's text item delimiters to ""
                    return outputText
                end run
                """
            case .fetchArtwork:
                """
                on fetchArtwork(playlistID)
                    tell application id "com.apple.Music"
                        try
                            set targetPlaylist to user playlist id playlistID
                            if (count of tracks of targetPlaylist) is 0 then return missing value
                            set firstTrack to track 1 of targetPlaylist
                            if (count of artworks of firstTrack) is 0 then return missing value
                            return raw data of artwork 1 of firstTrack
                        on error
                            return missing value
                        end try
                    end tell
                end fetchArtwork
                """
            case .playPlaylist:
                """
                on playPlaylist(playlistID, shuffleValue)
                    tell application id "com.apple.Music"
                        set shuffle enabled to shuffleValue
                        play user playlist id playlistID
                    end tell
                end playPlaylist
                """
            case .playPause:
                """
                on playPause()
                    tell application id "com.apple.Music" to playpause
                end playPause
                """
            case .nextTrack:
                """
                on nextTrack()
                    tell application id "com.apple.Music" to next track
                end nextTrack
                """
            case .previousTrack:
                """
                on previousTrack()
                    tell application id "com.apple.Music" to previous track
                end previousTrack
                """
            case .seek:
                """
                on seekTo(secondsValue)
                    tell application id "com.apple.Music"
                        if player state is not stopped then set player position to secondsValue
                    end tell
                end seekTo
                """
            case .setShuffle:
                """
                on setShuffle(shuffleValue)
                    tell application id "com.apple.Music"
                        set shuffle enabled to shuffleValue
                    end tell
                end setShuffle
                """
            }
        }

        var handlerName: String? {
            switch self {
            case .fetchPlaylists:
                nil
            case .fetchArtwork:
                "fetchArtwork"
            case .playPlaylist:
                "playPlaylist"
            case .playPause:
                "playPause"
            case .nextTrack:
                "nextTrack"
            case .previousTrack:
                "previousTrack"
            case .seek:
                "seekTo"
            case .setShuffle:
                "setShuffle"
            }
        }
    }

    private enum ControllerError: Error, LocalizedError {
        case scriptUnavailable
        case scriptExecutionFailed

        var errorDescription: String? {
            switch self {
            case .scriptUnavailable:
                "Music AppleScript could not be compiled."
            case .scriptExecutionFailed:
                "Music AppleScript execution failed."
            }
        }
    }

    private enum ScriptArgument: Sendable {
        case string(String)
        case bool(Bool)
        case double(Double)

        func descriptor() -> NSAppleEventDescriptor {
            switch self {
            case .string(let value):
                NSAppleEventDescriptor(string: value)
            case .bool(let value):
                NSAppleEventDescriptor(boolean: value)
            case .double(let value):
                NSAppleEventDescriptor(double: value)
            }
        }
    }

    private static let musicBundleIdentifier = "com.apple.Music"
    private static let recordSeparator = Character(UnicodeScalar(30))
    private static let unitSeparator = Character(UnicodeScalar(31))

    private let logger = Logger(subsystem: "com.vinylfy.app", category: "MusicController")
    private let queue = DispatchQueue(label: "com.vinylfy.musiccontroller")
    private var scripts: [ScriptKind: NSAppleScript] = [:]
    private var artworkCache: [String: Data] = [:]

    public init() {}

    public var isMusicRunning: Bool {
        Self.isApplicationRunning(bundleIdentifier: Self.musicBundleIdentifier)
    }

    public func fetchPlaylists(
        _ completion: @escaping @Sendable (Result<[MusicPlaylist], Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isMusicRunning else {
                completion(.success([]))
                return
            }

            guard let descriptor = self.executeScript(.fetchPlaylists) else {
                completion(.failure(ControllerError.scriptExecutionFailed))
                return
            }

            completion(.success(Self.parsePlaylists(from: descriptor.stringValue ?? "")))
        }
    }

    public func fetchArtwork(
        forPlaylist id: String,
        _ completion: @escaping @Sendable (Data?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isMusicRunning else {
                completion(nil)
                return
            }

            if let cached = self.artworkCache[id] {
                completion(cached)
                return
            }

            guard let descriptor = self.executeScript(
                .fetchArtwork,
                arguments: [NSAppleEventDescriptor(string: id)]
            ), let pngData = Self.pngData(from: descriptor.data) else {
                completion(nil)
                return
            }

            self.artworkCache[id] = pngData
            completion(pngData)
        }
    }

    public func playPlaylist(id: String, shuffle: Bool) {
        performTransport(
            .playPlaylist,
            arguments: [
                .string(id),
                .bool(shuffle),
            ]
        )
    }

    public func playPause() {
        performTransport(.playPause)
    }

    public func nextTrack() {
        performTransport(.nextTrack)
    }

    public func previousTrack() {
        performTransport(.previousTrack)
    }

    public func seek(toSeconds seconds: Double) {
        performTransport(.seek, arguments: [.double(seconds)])
    }

    public func setShuffle(_ on: Bool) {
        performTransport(.setShuffle, arguments: [.bool(on)])
    }

    public func launchMusicIfNeeded() {
        queue.async { [weak self] in
            self?.launchMusicIfNeededOnMain()
        }
    }

    private func performTransport(
        _ kind: ScriptKind,
        arguments: [ScriptArgument] = []
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.launchMusicIfNeededOnMain()
            let descriptors = arguments.map { $0.descriptor() }
            guard self.executeScript(kind, arguments: descriptors) != nil else {
                self.logger.error("music_controller_transport_failed kind=\(String(describing: kind), privacy: .public)")
                return
            }
        }
    }

    private func launchMusicIfNeededOnMain() {
        guard !Self.isApplicationRunning(bundleIdentifier: Self.musicBundleIdentifier) else {
            return
        }

        runOnMain {
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: Self.musicBundleIdentifier
            ) else {
                return
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            let logger = self.logger
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [logger] _, error in
                if let error {
                    logger.error("music_launch_failed error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func executeScript(
        _ kind: ScriptKind,
        arguments: [NSAppleEventDescriptor] = []
    ) -> NSAppleEventDescriptor? {
        runOnMain {
            guard let script = self.compiledScript(kind) else {
                self.logger.error("music_script_compile_failed kind=\(String(describing: kind), privacy: .public)")
                return nil
            }

            var error: NSDictionary?
            let descriptor: NSAppleEventDescriptor?
            if let handlerName = kind.handlerName {
                descriptor = script.executeAppleEvent(
                    Self.subroutineEvent(name: handlerName, arguments: arguments),
                    error: &error
                )
            } else {
                descriptor = script.executeAndReturnError(&error)
            }

            guard error == nil else {
                self.logger.error("music_script_error kind=\(String(describing: kind), privacy: .public) error=\(String(describing: error), privacy: .public)")
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
            logger.error("music_script_compile_error kind=\(String(describing: kind), privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }

        scripts[kind] = script
        return script
    }

    private static func subroutineEvent(
        name: String,
        arguments: [NSAppleEventDescriptor]
    ) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        event.setParam(NSAppleEventDescriptor(string: name), forKeyword: AEKeyword(keyASSubroutineName))

        let argumentsDescriptor = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            argumentsDescriptor.insert(argument, at: index + 1)
        }
        event.setParam(argumentsDescriptor, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    private func runOnMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }

        return DispatchQueue.main.sync(execute: work)
    }

    private static func parsePlaylists(from text: String) -> [MusicPlaylist] {
        guard !text.isEmpty else {
            return []
        }

        return text.split(separator: recordSeparator, omittingEmptySubsequences: true).compactMap { row in
            let fields = row.split(separator: unitSeparator, omittingEmptySubsequences: false)
            guard fields.count >= 4 else {
                return nil
            }

            let id = String(fields[0])
            let name = String(fields[1])
            let trackCount = Int(fields[2]) ?? 0
            let durationText = String(fields[3])
            return MusicPlaylist(
                id: id,
                name: name,
                trackCount: trackCount,
                durationSeconds: durationText.isEmpty ? nil : Double(durationText)
            )
        }
    }

    private static func isApplicationRunning(bundleIdentifier: String) -> Bool {
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
