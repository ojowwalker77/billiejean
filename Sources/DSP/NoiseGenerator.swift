import Foundation

public struct NoiseGenerator: Sendable {
    private var state: UInt64 = 0x7f4a7c159e3779b9
    private var crackleEnvelope: Float = 0
    private var hissLeftState: Float = 0
    private var hissRightState: Float = 0
    private var crackleLeftState: Float = 0
    private var crackleRightState: Float = 0
    private var configuredSampleRate: Double = 0
    private var hissAlpha: Float = 0
    private var crackleAlpha: Float = 0
    private var crackleDecay: Float = 0

    public init(seed: UInt64 = 0x7f4a7c159e3779b9) {
        state = seed == 0 ? 0x7f4a7c159e3779b9 : seed
    }

    public mutating func sample(
        sampleRate: Double,
        hissLevel: Float,
        crackleRate: Float,
        crackleIntensity: Float
    ) -> (Float, Float) {
        configureIfNeeded(sampleRate: sampleRate)

        let hissGain = max(0, hissLevel) * hissInputGain(sampleRate: sampleRate)
        let hissLeftInput = nextBipolar() * hissGain
        let hissRightInput = nextBipolar() * hissGain
        let hissLeft = Self.lowPass(input: hissLeftInput, state: &hissLeftState, alpha: hissAlpha)
        let hissRight = Self.lowPass(input: hissRightInput, state: &hissRightState, alpha: hissAlpha)

        let probability = Float(1 - exp(-Double(max(0, crackleRate)) / sampleRate))
        if nextUnit() < probability {
            let baseAmplitude = 0.05 * powf(nextUnit(), 2.5)
            let popScale: Float = nextUnit() < 0.05 ? 3 : 1
            crackleEnvelope += baseAmplitude * popScale * min(2, max(0, crackleIntensity))
        }

        let crackleLeftInput = crackleEnvelope * nextBipolar()
        let crackleRightInput = crackleEnvelope * nextBipolar()
        let crackleLeft = Self.lowPass(input: crackleLeftInput, state: &crackleLeftState, alpha: crackleAlpha)
        let crackleRight = Self.lowPass(input: crackleRightInput, state: &crackleRightState, alpha: crackleAlpha)
        crackleEnvelope *= crackleDecay

        return (hissLeft + crackleLeft, hissRight + crackleRight)
    }

    private mutating func configureIfNeeded(sampleRate: Double) {
        guard sampleRate != configuredSampleRate else {
            return
        }
        configuredSampleRate = sampleRate
        hissAlpha = onePoleAlpha(cutoff: 7_000, sampleRate: sampleRate)
        crackleAlpha = onePoleAlpha(cutoff: 9_000, sampleRate: sampleRate)
        crackleDecay = Float(exp(-1 / (0.0015 * sampleRate)))
    }

    private func onePoleAlpha(cutoff: Double, sampleRate: Double) -> Float {
        Float(exp(-2 * Double.pi * cutoff / sampleRate))
    }

    private func hissInputGain(sampleRate: Double) -> Float {
        let alpha = Double(hissAlpha)
        let filteredUniformRMS = sqrt((1 - alpha) / (1 + alpha)) / sqrt(3)
        return Float(0.001 / filteredUniformRMS)
    }

    private static func lowPass(input: Float, state: inout Float, alpha: Float) -> Float {
        state = (1 - alpha) * input + alpha * state
        return state
    }

    private mutating func nextUInt() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    private mutating func nextUnit() -> Float {
        Float(nextUInt() >> 40) / Float(1 << 24)
    }

    private mutating func nextBipolar() -> Float {
        nextUnit() * 2 - 1
    }
}
