import AVFoundation
import DSP
import XCTest

final class VinylProcessorTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let chunkFrames = 4_800

    func testSilenceNoiseFloor() throws {
        let processor = VinylProcessor(sampleRate: sampleRate)
        var samples: [Float] = []

        for _ in 0..<20 {
            let input = try makeBuffer(frames: chunkFrames)
            let output = try XCTUnwrap(processor.process(input))
            appendSamples(from: output, to: &samples)
        }

        let skipped = Array(samples.dropFirst(chunkFrames * 2))
        let rmsDB = decibels(rms(skipped))
        let peak = skipped.map { abs($0) }.max() ?? 0

        XCTAssertGreaterThanOrEqual(rmsDB, -63)
        XCTAssertLessThanOrEqual(rmsDB, -54)
        XCTAssertLessThan(peak, Float(pow(10, -26.0 / 20.0)))
    }

    func testUnityIshGainForSine() throws {
        let processor = VinylProcessor(sampleRate: sampleRate)
        let inputRMS = Float(0.25 / sqrt(2))
        var samples: [Float] = []

        for chunk in 0..<20 {
            let input = try makeBuffer(frames: chunkFrames) { frame, channel in
                let absoluteFrame = chunk * self.chunkFrames + frame
                let phase = 2 * Double.pi * 1_000 * Double(absoluteFrame) / self.sampleRate
                return Float(sin(phase) * 0.25) * (channel == 0 ? 1 : 0.98)
            }
            let output = try XCTUnwrap(processor.process(input))
            appendSamples(from: output, to: &samples)
        }

        let outputRMS = rms(Array(samples.dropFirst(chunkFrames * 2)))
        let gainDB = decibels(outputRMS / inputRMS)
        let peak = samples.map { abs($0) }.max() ?? 0

        XCTAssertGreaterThanOrEqual(gainDB, -3)
        XCTAssertLessThanOrEqual(gainDB, 3)
        XCTAssertLessThanOrEqual(peak, 1)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite })
    }

    func testNoDCGarbage() throws {
        let processor = VinylProcessor(sampleRate: sampleRate)
        var samples: [Float] = []

        for _ in 0..<20 {
            let input = try makeBuffer(frames: chunkFrames)
            let output = try XCTUnwrap(processor.process(input))
            appendSamples(from: output, to: &samples)
        }

        let skipped = Array(samples.dropFirst(chunkFrames * 2))
        let mean = skipped.reduce(Float(0), +) / Float(skipped.count)
        XCTAssertLessThan(abs(mean), 0.001)
    }

    func testInterleavedInputProducesDeinterleavedOutputWithSameFrameLength() throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
        ),
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)),
            let data = input.floatChannelData else {
            XCTFail("Could not create interleaved buffer")
            return
        }
        input.frameLength = AVAudioFrameCount(chunkFrames)

        for frame in 0..<chunkFrames {
            data[0][frame * 2] = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate) * 0.1)
            data[0][frame * 2 + 1] = Float(sin(2 * Double.pi * 550 * Double(frame) / sampleRate) * 0.1)
        }

        let processor = VinylProcessor(sampleRate: sampleRate)
        let output = try XCTUnwrap(processor.process(input))

        XCTAssertFalse(output.format.isInterleaved)
        XCTAssertEqual(output.frameLength, input.frameLength)
        XCTAssertEqual(output.format.channelCount, input.format.channelCount)
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

    private func appendSamples(from buffer: AVAudioPCMBuffer, to samples: inout [Float]) {
        guard let data = buffer.floatChannelData else {
            return
        }

        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                samples.append(data[channel][frame])
            }
        }
    }

    private func rms(_ samples: [Float]) -> Float {
        let sumSquares = samples.reduce(Double(0)) { partial, sample in
            partial + Double(sample * sample)
        }
        return Float(sqrt(sumSquares / Double(samples.count)))
    }

    private func decibels(_ value: Float) -> Float {
        20 * log10(max(value, 1e-12))
    }

    private enum TestError: Error {
        case bufferCreationFailed
    }
}
