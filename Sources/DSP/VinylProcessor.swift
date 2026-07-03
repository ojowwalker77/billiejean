import AVFoundation
import Foundation

public struct VinylParameters: Sendable {
    public var drive: Float
    public var hissLevel: Float
    public var crackleRate: Float
    public var crackleIntensity: Float
    public var wowDepth: Float
    public var stereoWidth: Float
    public var outputGain: Float

    public init(
        drive: Float = 0.35,
        hissLevel: Float = 1,
        crackleRate: Float = 2.5,
        crackleIntensity: Float = 1,
        wowDepth: Float = 1,
        stereoWidth: Float = 0.9,
        outputGain: Float = 1
    ) {
        self.drive = drive
        self.hissLevel = hissLevel
        self.crackleRate = crackleRate
        self.crackleIntensity = crackleIntensity
        self.wowDepth = wowDepth
        self.stereoWidth = stereoWidth
        self.outputGain = outputGain
    }
}

public final class VinylProcessor: @unchecked Sendable {
    private let sampleRate: Double
    private var parameters: VinylParameters
    public var isBypassed: Bool = false
    private var leftHighPass: BiquadFilter
    private var rightHighPass: BiquadFilter
    private var leftLowShelf: BiquadFilter
    private var rightLowShelf: BiquadFilter
    private var leftLowPass: BiquadFilter
    private var rightLowPass: BiquadFilter
    private var wowFlutter: WowFlutter
    private var noise: NoiseGenerator

    public init(sampleRate: Double, parameters: VinylParameters = VinylParameters()) {
        self.sampleRate = sampleRate
        self.parameters = parameters
        leftHighPass = BiquadFilter.highPass(sampleRate: sampleRate, cutoff: 30)
        rightHighPass = BiquadFilter.highPass(sampleRate: sampleRate, cutoff: 30)
        leftLowShelf = BiquadFilter.lowShelf(sampleRate: sampleRate, cutoff: 150, gainDB: 1.5)
        rightLowShelf = BiquadFilter.lowShelf(sampleRate: sampleRate, cutoff: 150, gainDB: 1.5)
        leftLowPass = BiquadFilter.lowPass(sampleRate: sampleRate, cutoff: 15_500)
        rightLowPass = BiquadFilter.lowPass(sampleRate: sampleRate, cutoff: 15_500)
        wowFlutter = WowFlutter(sampleRate: sampleRate)
        noise = NoiseGenerator()
    }

    public func updateParameters(_ parameters: VinylParameters) {
        self.parameters = parameters
    }

    public func process(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let inputChannels = input.floatChannelData else {
            return nil
        }

        let frameCount = Int(input.frameLength)
        let channelCount = Int(input.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            return nil
        }

        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: input.format.sampleRate,
            channels: input.format.channelCount
        ),
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: input.frameLength),
              let outputChannels = output.floatChannelData else {
            return nil
        }
        output.frameLength = input.frameLength

        let leftOut = outputChannels[0]
        let rightOut = channelCount > 1 ? outputChannels[1] : nil
        let inputIsInterleaved = input.format.isInterleaved
        let inputStride = input.stride

        if isBypassed {
            copyInput(
                inputChannels,
                to: outputChannels,
                frameCount: frameCount,
                channelCount: channelCount,
                inputStride: inputStride,
                inputIsInterleaved: inputIsInterleaved
            )
            return output
        }

        for frame in 0..<frameCount {
            let dryLeft = Self.sample(
                from: inputChannels,
                channel: 0,
                frame: frame,
                stride: inputStride,
                isInterleaved: inputIsInterleaved
            )
            let dryRight = channelCount > 1
                ? Self.sample(
                    from: inputChannels,
                    channel: 1,
                    frame: frame,
                    stride: inputStride,
                    isInterleaved: inputIsInterleaved
                )
                : dryLeft
            var wetLeft = shape(dryLeft, drive: parameters.drive)
            var wetRight = shape(dryRight, drive: parameters.drive)

            wetLeft = leftLowPass.process(leftLowShelf.process(leftHighPass.process(wetLeft)))
            wetRight = rightLowPass.process(rightLowShelf.process(rightHighPass.process(wetRight)))

            let wobbled = wowFlutter.process(
                left: wetLeft,
                right: wetRight,
                depth: parameters.wowDepth
            )
            wetLeft = wobbled.0
            wetRight = wobbled.1

            let surface = noise.sample(
                sampleRate: sampleRate,
                hissLevel: parameters.hissLevel,
                crackleRate: parameters.crackleRate,
                crackleIntensity: parameters.crackleIntensity
            )
            wetLeft += surface.0
            wetRight += surface.1

            let narrowed = StereoWidth.apply(left: wetLeft, right: wetRight, width: parameters.stereoWidth)
            wetLeft = narrowed.0
            wetRight = narrowed.1

            leftOut[frame] = clamp(wetLeft * parameters.outputGain)
            rightOut?[frame] = clamp(wetRight * parameters.outputGain)
        }

        if channelCount > 2 {
            copyInput(
                inputChannels,
                to: outputChannels,
                frameCount: frameCount,
                channelCount: channelCount,
                inputStride: inputStride,
                inputIsInterleaved: inputIsInterleaved,
                startingAtChannel: 2
            )
        }

        return output
    }

    private func copyInput(
        _ inputChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        to outputChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        channelCount: Int,
        inputStride: Int,
        inputIsInterleaved: Bool,
        startingAtChannel: Int = 0
    ) {
        guard startingAtChannel < channelCount else {
            return
        }

        for channel in startingAtChannel..<channelCount {
            if inputIsInterleaved {
                for frame in 0..<frameCount {
                    outputChannels[channel][frame] = Self.sample(
                        from: inputChannels,
                        channel: channel,
                        frame: frame,
                        stride: inputStride,
                        isInterleaved: true
                    )
                }
            } else {
                memcpy(outputChannels[channel], inputChannels[channel], frameCount * MemoryLayout<Float>.size)
            }
        }
    }

    private static func sample(
        from channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channel: Int,
        frame: Int,
        stride: Int,
        isInterleaved: Bool
    ) -> Float {
        if isInterleaved {
            return channels[0][frame * stride + channel]
        }
        return channels[channel][frame]
    }

    private func shape(_ sample: Float, drive: Float) -> Float {
        let clampedDrive = max(0, drive)
        let gain = 1 + 2 * clampedDrive
        return tanh(gain * sample) / gain
    }

    private func clamp(_ sample: Float) -> Float {
        min(1, max(-1, sample))
    }
}
