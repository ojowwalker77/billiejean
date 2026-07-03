@preconcurrency import AVFoundation
import AudioCapture
import DSP
import Foundation
import VinylEngine

@available(macOS 14.2, *)
final class HearItRunner: @unchecked Sendable {
    private let engine = HearItEngine(debugLogging: true)
    private let bypass: Bool

    init(bypass: Bool = false) {
        self.bypass = bypass
    }

    func run() throws {
        engine.statsHandler = { [weak engine] stats in
            if stats.processed == 1 || stats.processed % 250 == 0 {
                let meters = engine?.meters(maxBins: 200)
                let inPeak = meters?.inputLevels.max() ?? 0
                let outPeak = meters?.outputLevels.max() ?? 0
                print(String(format: "processed=%d queued=%d dropped=%d underruns=%d inPeak=%.3f outPeak=%.3f",
                             stats.processed, stats.queued, stats.dropped, stats.underruns, inPeak, outPeak))
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
        } else {
            let runner = HearItRunner(bypass: CommandLine.arguments.contains("--bypass"))
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
