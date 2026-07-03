@preconcurrency import AVFoundation
import AudioCapture
import DSP
import Foundation
import NowPlaying
import VinylEngine

@available(macOS 14.2, *)
final class HearItRunner: @unchecked Sendable {
    private let engine = HearItEngine(debugLogging: true)
    private let bypass: Bool
    private let tapMusicOnly: Bool

    init(bypass: Bool = false, tapMusicOnly: Bool = false) {
        self.bypass = bypass
        self.tapMusicOnly = tapMusicOnly
    }

    func run() throws {
        if tapMusicOnly {
            engine.tapTarget = .bundle("com.apple.Music")
            print("Tap scope: Music app only.")
        }
        engine.statsHandler = { [weak engine] stats in
            if stats.processed == 1 || stats.processed % 250 == 0 {
                let meters = engine?.meters(maxBins: 200)
                let inPeak = meters?.inputLevels.max() ?? 0
                let outPeak = meters?.outputLevels.max() ?? 0
                print(String(format: "processed=%d queued=%d dropped=%d underruns=%d restarts=%d inPeak=%.3f outPeak=%.3f",
                             stats.processed, stats.queued, stats.dropped, stats.underruns, stats.restarts, inPeak, outPeak))
            }
        }
        engine.bypass = bypass
        try engine.start()

        print("VinylfyHearIt is running.")
        if bypass {
            print("DSP bypass is enabled.")
        }
        if engine.isExcludingCurrentProcess {
            print("Excluding Vinylfy playback process from the tap.")
        } else {
            print("Warning: could not exclude Vinylfy playback from the global tap.")
        }
        print("Play audio in Music/Spotify/browser and listen for the vinyl-processed copy.")
        print("Press Return to stop.")
        print("System audio tap started.")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.engine.stats().processed == 0 else { return }
            print("No tap buffers yet. Start playback in another app, or grant Audio Capture permission if macOS asks.")
        }

        _ = readLine()
        stop()
    }

    private func stop() {
        engine.stop()
        let stats = engine.stats()
        print("Stopped. processed=\(stats.processed) dropped=\(stats.dropped) underruns=\(stats.underruns)")
    }
}

@available(macOS 14.2, *)
final class ProbeDoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func isSet() -> Bool { lock.withLock { value } }
}

/// `--playlists`: fetch and print the user's Music playlists via MusicController.
@available(macOS 14.2, *)
enum PlaylistProbe {
    static func run() throws {
        let controller = MusicController()
        guard controller.isMusicRunning else {
            print("Music is not running.")
            return
        }
        // MusicController runs its AppleScript on the main thread, so keep the
        // main run loop pumping instead of blocking it with a semaphore.
        let done = ProbeDoneFlag()
        controller.fetchPlaylists { result in
            switch result {
            case .success(let playlists):
                print("playlists=\(playlists.count)")
                for p in playlists.prefix(30) {
                    let mins = p.durationSeconds.map { String(format: "%.0fm", $0 / 60) } ?? "?"
                    print("- [\(p.id)] \(p.name) (\(p.trackCount) tracks, \(mins))")
                }
            case .failure(let error):
                print("fetchPlaylists failed: \(error.localizedDescription)")
            }
            done.set()
        }
        let deadline = Date().addingTimeInterval(20)
        while !done.isSet() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
    }
}

/// `--tracks <playlistID>`: fetch and print tracks from a Music playlist.
@available(macOS 14.2, *)
enum TracksProbe {
    static func run(playlistID: String) throws {
        let controller = MusicController()
        guard controller.isMusicRunning else {
            print("Music is not running.")
            return
        }

        let done = ProbeDoneFlag()
        controller.fetchTracks(forPlaylist: playlistID) { result in
            switch result {
            case .success(let tracks):
                print("tracks=\(tracks.count)")
                for track in tracks.prefix(30) {
                    let mins = track.durationSeconds.map { String(format: "%.1fm", $0 / 60) } ?? "?"
                    print("- \(track.index). [\(track.id)] \(track.name) - \(track.artist) (\(mins))")
                }
            case .failure(let error):
                print("fetchTracks failed: \(error.localizedDescription)")
            }
            done.set()
        }
        let deadline = Date().addingTimeInterval(20)
        while !done.isSet() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
    }
}

@available(macOS 14.2, *)
enum DemoRunner {
    static func run(seconds: Double) throws {
        let sampleRate = 48_000.0
        let channels: AVAudioChannelCount = 2
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioError.invalidTapFormat
        }
        input.frameLength = frameCount

        guard let channelData = input.floatChannelData else {
            throw AudioError.invalidTapFormat
        }

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let envelope = min(1, t / 0.05) * min(1, (seconds - t) / 0.2)
            let left =
                sin(2 * Double.pi * 220 * t) * 0.20 +
                sin(2 * Double.pi * 277.18 * t) * 0.11 +
                sin(2 * Double.pi * 329.63 * t) * 0.10
            let right =
                sin(2 * Double.pi * 220.7 * t) * 0.18 +
                sin(2 * Double.pi * 277.18 * t) * 0.10 +
                sin(2 * Double.pi * 392.0 * t) * 0.10
            channelData[0][frame] = Float(left * envelope)
            channelData[1][frame] = Float(right * envelope)
        }

        let processor = VinylProcessor(sampleRate: sampleRate)
        guard let processed = processor.process(input) else {
            throw AudioError.mixFailed("Could not process demo tone.")
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.9
        try engine.start()

        let done = DispatchSemaphore(value: 0)
        player.scheduleBuffer(processed) {
            done.signal()
        }
        player.play()

        print("Playing \(String(format: "%.1f", seconds))s vinyl DSP demo.")
        _ = done.wait(timeout: .now() + seconds + 2)
        player.stop()
        engine.stop()
        print("Demo complete.")
    }
}

if #available(macOS 14.2, *) {
    do {
        if CommandLine.arguments.contains("--demo") {
            let seconds = secondsArgument() ?? 5
            try DemoRunner.run(seconds: seconds)
        } else if CommandLine.arguments.contains("--playlists") {
            try PlaylistProbe.run()
        } else if let playlistID = tracksArgument() {
            try TracksProbe.run(playlistID: playlistID)
        } else {
            let runner = HearItRunner(
                bypass: CommandLine.arguments.contains("--bypass"),
                tapMusicOnly: CommandLine.arguments.contains("--tap-music")
            )
            try runner.run()
        }
    } catch {
        fputs("VinylfyHearIt failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else {
    fputs("Vinylfy requires macOS 14.2 or later.\n", stderr)
    exit(1)
}

private func secondsArgument() -> Double? {
    guard let index = CommandLine.arguments.firstIndex(of: "--seconds"),
          CommandLine.arguments.indices.contains(index + 1) else {
        return nil
    }
    return Double(CommandLine.arguments[index + 1])
}

private func tracksArgument() -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: "--tracks"),
          CommandLine.arguments.indices.contains(index + 1) else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}
