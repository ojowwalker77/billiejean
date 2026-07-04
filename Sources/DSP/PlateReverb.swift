import Foundation

public final class PlateReverb: @unchecked Sendable {
    public var roomSize: Float {
        get { roomSizeValue }
        set { roomSizeValue = Self.clamp01(newValue) }
    }

    public var damping: Float {
        get { dampingValue }
        set { dampingValue = Self.clamp01(newValue) }
    }

    public var mix: Float {
        get { mixValue }
        set { mixValue = Self.clamp01(newValue) }
    }

    private var leftCombs: [CombFilter]
    private var rightCombs: [CombFilter]
    private var leftAllpasses: [AllpassFilter]
    private var rightAllpasses: [AllpassFilter]
    private var roomSizeValue: Float
    private var dampingValue: Float
    private var mixValue: Float

    private static let combTunings = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassTunings = [556, 441, 341, 225]
    private static let stereoSpread = 23
    private static let inputGain: Float = 0.08

    public init(sampleRate: Double, roomSize: Float = 0.84, damping: Float = 0.45, mix: Float = 0.32) {
        let scale = sampleRate / 44_100
        roomSizeValue = Self.clamp01(roomSize)
        dampingValue = Self.clamp01(damping)
        mixValue = Self.clamp01(mix)
        leftCombs = Self.combTunings.map { CombFilter(delay: Self.scaledDelay($0, scale: scale)) }
        rightCombs = Self.combTunings.map {
            CombFilter(delay: Self.scaledDelay($0 + Self.stereoSpread, scale: scale))
        }
        leftAllpasses = Self.allpassTunings.map { AllpassFilter(delay: Self.scaledDelay($0, scale: scale)) }
        rightAllpasses = Self.allpassTunings.map {
            AllpassFilter(delay: Self.scaledDelay($0 + Self.stereoSpread, scale: scale))
        }
    }

    public func reset() {
        for comb in leftCombs {
            comb.reset()
        }
        for comb in rightCombs {
            comb.reset()
        }
        for allpass in leftAllpasses {
            allpass.reset()
        }
        for allpass in rightAllpasses {
            allpass.reset()
        }
    }

    public func processSample(left: Float, right: Float) -> (Float, Float) {
        let wet = processWetSample(left: left, right: right)
        let clampedMix = mixValue
        let dryGain = Float(cos(Double(clampedMix) * Double.pi * 0.5))
        let wetGain = Float(sin(Double(clampedMix) * Double.pi * 0.5))
        return (
            left * dryGain + wet.0 * wetGain,
            right * dryGain + wet.1 * wetGain
        )
    }

    public func processWetSample(left: Float, right: Float) -> (Float, Float) {
        let feedback = 0.7 + 0.28 * roomSizeValue
        let damp = dampingValue
        var wetLeft: Float = 0
        var wetRight: Float = 0
        let inputLeft = left * Self.inputGain
        let inputRight = right * Self.inputGain

        for comb in leftCombs {
            wetLeft += comb.process(inputLeft, feedback: feedback, damping: damp)
        }
        for comb in rightCombs {
            wetRight += comb.process(inputRight, feedback: feedback, damping: damp)
        }

        wetLeft *= 0.125
        wetRight *= 0.125

        for allpass in leftAllpasses {
            wetLeft = allpass.process(wetLeft)
        }
        for allpass in rightAllpasses {
            wetRight = allpass.process(wetRight)
        }

        return (wetLeft, wetRight)
    }

    private static func scaledDelay(_ delay: Int, scale: Double) -> Int {
        max(1, Int(round(Double(delay) * scale)))
    }

    private static func clamp01(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}

private final class CombFilter {
    private var buffer: [Float]
    private var index: Int = 0
    private var filterStore: Float = 0

    init(delay: Int) {
        buffer = Array(repeating: 0, count: max(1, delay))
    }

    func reset() {
        for index in 0..<buffer.count {
            buffer[index] = 0
        }
        self.index = 0
        filterStore = 0
    }

    func process(_ input: Float, feedback: Float, damping: Float) -> Float {
        let output = buffer[index]
        filterStore = output * (1 - damping) + filterStore * damping
        buffer[index] = input + filterStore * feedback

        index += 1
        if index == buffer.count {
            index = 0
        }

        return output
    }
}

private final class AllpassFilter {
    private var buffer: [Float]
    private var index: Int = 0
    private let feedback: Float = 0.5

    init(delay: Int) {
        buffer = Array(repeating: 0, count: max(1, delay))
    }

    func reset() {
        for index in 0..<buffer.count {
            buffer[index] = 0
        }
        self.index = 0
    }

    func process(_ input: Float) -> Float {
        let buffered = buffer[index]
        let output = buffered - input
        buffer[index] = input + buffered * feedback

        index += 1
        if index == buffer.count {
            index = 0
        }

        return output
    }
}
