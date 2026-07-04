import AVFoundation
import Foundation

public struct SlowedParameters: Sendable {
    public var rate: Double
    public var reverbMix: Float
    public var roomSize: Float
    public var damping: Float
    public var outputGain: Float

    public init(
        rate: Double = 0.85,
        reverbMix: Float = 0.32,
        roomSize: Float = 0.84,
        damping: Float = 0.45,
        outputGain: Float = 1
    ) {
        self.rate = rate
        self.reverbMix = reverbMix
        self.roomSize = roomSize
        self.damping = damping
        self.outputGain = outputGain
    }
}

public final class SlowedProcessor: @unchecked Sendable {
    private let sampleRate: Double
    private var parameters: SlowedParameters
    public var isBypassed: Bool = false
    private var resampler: VarispeedResampler
    private var reverb: PlateReverb
    private let signalThreshold: Float = 1e-4
    private let gateClosedThreshold: Float = 1e-4
    private let gateHoldSamples: Int
    private let gateAttackCoef: Float
    private let gateReleaseCoef: Float
    private var gateHoldCountdown: Int = 0
    private var gateGain: Float = 0
    private var inputFramesConsumed: Int64 = 0
    private var outputFramesEmitted: Int64 = 0

    public var pendingOutputSeconds: Double {
        Double(outputFramesEmitted - inputFramesConsumed) / sampleRate
    }

    public init(sampleRate: Double, parameters: SlowedParameters = SlowedParameters()) {
        self.sampleRate = sampleRate
        self.parameters = parameters
        gateHoldSamples = Int(1.5 * sampleRate)
        gateAttackCoef = Float(exp(-1 / (0.06 * sampleRate)))
        gateReleaseCoef = Float(exp(-1 / (0.35 * sampleRate)))
        resampler = VarispeedResampler(sampleRate: sampleRate, rate: parameters.rate)
        reverb = PlateReverb(
            sampleRate: sampleRate,
            roomSize: parameters.roomSize,
            damping: parameters.damping,
            mix: parameters.reverbMix
        )
    }

    public func updateParameters(_ parameters: SlowedParameters) {
        self.parameters = parameters
        resampler.rate = parameters.rate
        reverb.roomSize = parameters.roomSize
        reverb.damping = parameters.damping
        reverb.mix = parameters.reverbMix
    }

    public func resetDebt() {
        inputFramesConsumed = 0
        outputFramesEmitted = 0
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

        let outputCapacity = AVAudioFrameCount(Int(ceil(Double(frameCount) / 0.5)) + 16)
        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: input.format.sampleRate,
            channels: input.format.channelCount
        ),
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity),
            let outputChannels = output.floatChannelData else {
            return nil
        }

        let inputIsInterleaved = input.format.isInterleaved
        let inputStride = input.stride

        if isBypassed {
            output.frameLength = input.frameLength
            copyInput(
                inputChannels,
                to: outputChannels,
                frameCount: frameCount,
                channelCount: channelCount,
                inputStride: inputStride,
                inputIsInterleaved: inputIsInterleaved
            )
            inputFramesConsumed += Int64(frameCount)
            outputFramesEmitted += Int64(frameCount)
            return output
        }

        resampler.rate = parameters.rate
        reverb.roomSize = parameters.roomSize
        reverb.damping = parameters.damping
        reverb.mix = parameters.reverbMix

        let leftOut = outputChannels[0]
        let rightOut = channelCount > 1 ? outputChannels[1] : nil
        let maxOutputFrames = Int(outputCapacity)
        let mix = min(1, max(0, parameters.reverbMix))
        let dryGain = Float(cos(Double(mix) * Double.pi * 0.5))
        let wetGain = Float(sin(Double(mix) * Double.pi * 0.5))
        let outputGain = parameters.outputGain
        var outputFrame = 0

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

            resampler.push(left: dryLeft, right: dryRight)
            drainResampler(
                toLeft: leftOut,
                right: rightOut,
                outputFrame: &outputFrame,
                maxOutputFrames: maxOutputFrames,
                dryGain: dryGain,
                wetGain: wetGain,
                outputGain: outputGain
            )
        }

        drainResampler(
            toLeft: leftOut,
            right: rightOut,
            outputFrame: &outputFrame,
            maxOutputFrames: maxOutputFrames,
            dryGain: dryGain,
            wetGain: wetGain,
            outputGain: outputGain
        )

        if channelCount > 2 {
            clearExtraChannels(outputChannels, frameCount: outputFrame, channelCount: channelCount)
        }

        output.frameLength = AVAudioFrameCount(outputFrame)
        inputFramesConsumed += Int64(frameCount)
        outputFramesEmitted += Int64(outputFrame)
        return output
    }

    private func drainResampler(
        toLeft leftOut: UnsafeMutablePointer<Float>,
        right rightOut: UnsafeMutablePointer<Float>?,
        outputFrame: inout Int,
        maxOutputFrames: Int,
        dryGain: Float,
        wetGain: Float,
        outputGain: Float
    ) {
        while outputFrame < maxOutputFrames {
            guard let dry = resampler.pullSample() else {
                return
            }

            updateGate(dryLeft: dry.0, dryRight: dry.1)
            let wet = reverb.processWetSample(left: dry.0, right: dry.1)
            let gatedWetGain = wetGain * gateGain

            leftOut[outputFrame] = clamp((dry.0 * dryGain + wet.0 * gatedWetGain) * outputGain)
            rightOut?[outputFrame] = clamp((dry.1 * dryGain + wet.1 * gatedWetGain) * outputGain)
            outputFrame += 1
        }
    }

    private func copyInput(
        _ inputChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        to outputChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        channelCount: Int,
        inputStride: Int,
        inputIsInterleaved: Bool
    ) {
        for channel in 0..<channelCount {
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

    private func clearExtraChannels(
        _ outputChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        channelCount: Int
    ) {
        guard frameCount > 0, channelCount > 2 else {
            return
        }

        for channel in 2..<channelCount {
            memset(outputChannels[channel], 0, frameCount * MemoryLayout<Float>.size)
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

    private func updateGate(dryLeft: Float, dryRight: Float) {
        if max(abs(dryLeft), abs(dryRight)) > signalThreshold {
            gateHoldCountdown = gateHoldSamples
        } else if gateHoldCountdown > 0 {
            gateHoldCountdown -= 1
        }

        let target: Float = gateHoldCountdown > 0 ? 1 : 0
        let coef = target > gateGain ? gateAttackCoef : gateReleaseCoef
        gateGain = target + coef * (gateGain - target)
    }

    private func clamp(_ sample: Float) -> Float {
        min(1, max(-1, sample))
    }
}
