import AVFoundation
import DSP
import XCTest

final class SlowedProcessorTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let chunkFrames = 4_800

    func testLengthAtSlowedRate() throws {
        let rate = 0.85
        let processor = SlowedProcessor(
            sampleRate: sampleRate,
            parameters: SlowedParameters(rate: rate, reverbMix: 0)
        )
        var inputFrames = 0
        var outputFrames = 0

        for chunk in 0..<100 {
            let input = try makeBuffer(frames: chunkFrames) { frame, _ in
                let absoluteFrame = chunk * self.chunkFrames + frame
                let phase = 2 * Double.pi * 220 * Double(absoluteFrame) / self.sampleRate
                return Float(sin(phase) * 0.2)
            }
            let output = try XCTUnwrap(processor.process(input))
            inputFrames += Int(input.frameLength)
            outputFrames += Int(output.frameLength)
        }

        let expected = Double(inputFrames) / rate
        let error = abs(Double(outputFrames) - expected) / expected
        XCTAssertLessThan(error, 0.01)
    }

    func testPitchDropsWithRate() throws {
        let rate = 0.8
        let processor = SlowedProcessor(
            sampleRate: sampleRate,
            parameters: SlowedParameters(rate: rate, reverbMix: 0)
        )
        var samples: [Float] = []

        for chunk in 0..<40 {
            let input = try makeBuffer(frames: chunkFrames) { frame, _ in
                let absoluteFrame = chunk * self.chunkFrames + frame
                let phase = 2 * Double.pi * 440 * Double(absoluteFrame) / self.sampleRate
                return Float(sin(phase) * 0.4)
            }
            let output = try XCTUnwrap(processor.process(input))
            appendLeftSamples(from: output, to: &samples)
        }

        let skipped = Array(samples.dropFirst(1_024))
        let frequency = frequencyFromZeroCrossings(skipped)
        XCTAssertEqual(frequency, 440 * rate, accuracy: 440 * rate * 0.03)
    }

    func testReverbTailExistsThenGateCloses() throws {
        let processor = SlowedProcessor(
            sampleRate: sampleRate,
            parameters: SlowedParameters(rate: 1, reverbMix: 0.5, roomSize: 0.84, damping: 0.45)
        )
        var samples: [Float] = []

        let impulse = try makeBuffer(frames: chunkFrames) { frame, _ in
            frame == 0 ? 1 : 0
        }
        appendLeftSamples(from: try XCTUnwrap(processor.process(impulse)), to: &samples)

        for _ in 0..<45 {
            let silence = try makeBuffer(frames: chunkFrames)
            appendLeftSamples(from: try XCTUnwrap(processor.process(silence)), to: &samples)
        }

        let halfSecond = Int(sampleRate * 0.5)
        let tailWindowEnd = min(samples.count, halfSecond + Int(sampleRate * 0.25))
        let lateTailPeak = peak(samples[halfSecond..<tailWindowEnd])
        XCTAssertGreaterThan(lateTailPeak, 1e-5)

        let finalWindowStart = max(0, samples.count - Int(sampleRate * 0.25))
        let finalPeak = peak(samples[finalWindowStart..<samples.count])
        XCTAssertLessThan(finalPeak, 1e-3)
    }

    func testRateOneMixZeroPassthrough() throws {
        let processor = SlowedProcessor(
            sampleRate: sampleRate,
            parameters: SlowedParameters(rate: 1, reverbMix: 0)
        )
        var inputSamples: [Float] = []
        var outputSamples: [Float] = []

        for chunk in 0..<10 {
            let input = try makeBuffer(frames: chunkFrames) { frame, channel in
                let absoluteFrame = chunk * self.chunkFrames + frame
                let frequency = channel == 0 ? 440.0 : 660.0
                let phase = 2 * Double.pi * frequency * Double(absoluteFrame) / self.sampleRate
                return Float(sin(phase) * 0.35)
            }
            appendLeftSamples(from: input, to: &inputSamples)
            appendLeftSamples(from: try XCTUnwrap(processor.process(input)), to: &outputSamples)
        }

        let count = min(inputSamples.count, outputSamples.count)
        let diff = zip(inputSamples[8..<count], outputSamples[8..<count]).map { $0 - $1 }
        XCTAssertLessThan(rms(diff), 1e-4)
    }

    private func makeBuffer(
        frames: Int,
        fill: (Int, Int) -> Float = { _, _ in 0 }
    ) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else {
            throw TestError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(frames)

        for channel in 0..<2 {
            for frame in 0..<frames {
                data[channel][frame] = fill(frame, channel)
            }
        }

        return buffer
    }

    private func appendLeftSamples(from buffer: AVAudioPCMBuffer, to samples: inout [Float]) {
        guard let data = buffer.floatChannelData else {
            return
        }

        for frame in 0..<Int(buffer.frameLength) {
            samples.append(data[0][frame])
        }
    }

    private func frequencyFromZeroCrossings(_ samples: [Float]) -> Double {
        guard samples.count > 1 else {
            return 0
        }

        var crossings = 0
        var previous = samples[0]
        for sample in samples.dropFirst() {
            if (previous < 0 && sample >= 0) || (previous >= 0 && sample < 0) {
                crossings += 1
            }
            previous = sample
        }

        let seconds = Double(samples.count) / sampleRate
        return Double(crossings) / (2 * seconds)
    }

    private func peak(_ samples: ArraySlice<Float>) -> Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }

    private func rms(_ samples: [Float]) -> Float {
        let sumSquares = samples.reduce(Double(0)) { partial, sample in
            partial + Double(sample * sample)
        }
        return Float(sqrt(sumSquares / Double(samples.count)))
    }

    private enum TestError: Error {
        case bufferCreationFailed
    }
}
