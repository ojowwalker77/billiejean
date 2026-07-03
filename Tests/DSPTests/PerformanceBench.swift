import AVFoundation
import XCTest
@testable import DSP

final class PerformanceBench: XCTestCase {
    func testRealtimeRatio() throws {
        let sampleRate = 48_000.0
        let chunkFrames: AVAudioFrameCount = 512
        let seconds = 10.0
        let chunkCount = Int(sampleRate * seconds / Double(chunkFrames))

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
              let channels = input.floatChannelData else {
            return XCTFail("buffer setup failed")
        }
        input.frameLength = chunkFrames
        for frame in 0..<Int(chunkFrames) {
            let t = Double(frame) / sampleRate
            let v = Float(sin(2 * .pi * 440 * t)) * 0.3
            channels[0][frame] = v
            channels[1][frame] = v
        }

        let processor = VinylProcessor(sampleRate: sampleRate)
        let start = Date()
        for _ in 0..<chunkCount {
            _ = processor.process(input)
        }
        let elapsed = Date().timeIntervalSince(start)
        let ratio = elapsed / seconds
        print("BENCH: processed \(seconds)s of 48k stereo in \(String(format: "%.3f", elapsed))s — ratio \(String(format: "%.2f", ratio))x realtime (per 512-frame IO cycle: \(String(format: "%.2f", ratio * 10.67))ms of 10.67ms budget)")
    }
}
