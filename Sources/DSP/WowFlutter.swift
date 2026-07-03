import Foundation

public struct WowFlutter: Sendable {
    private var leftDelay: [Float]
    private var rightDelay: [Float]
    private var writeIndex: Int = 0
    private var wowPhase: Double = 0
    private var flutterPhase: Double = 0
    private var wowDriftPhase: Double = 0
    private let sampleRate: Double
    private let baseDelay: Double

    private static let wowRate = 0.55
    private static let flutterRate = 6.5
    private static let wowDriftRate = 0.1
    private static let wowDeviation = 0.0010
    private static let flutterDeviation = 0.00035
    private static let maxDepth = 2.0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let maxWowAmplitude = Self.delayAmplitude(
            deviation: Self.wowDeviation,
            sampleRate: sampleRate,
            rate: Self.wowRate,
            depth: Self.maxDepth
        )
        let maxFlutterAmplitude = Self.delayAmplitude(
            deviation: Self.flutterDeviation,
            sampleRate: sampleRate,
            rate: Self.flutterRate,
            depth: Self.maxDepth
        )
        baseDelay = maxWowAmplitude + maxFlutterAmplitude + 8

        let maxDelay = baseDelay + maxWowAmplitude * 1.2 + maxFlutterAmplitude
        let capacity = max(64, Int(ceil(maxDelay)) + 8)
        leftDelay = Array(repeating: 0, count: capacity)
        rightDelay = Array(repeating: 0, count: capacity)
    }

    public mutating func process(left: Float, right: Float, depth: Float) -> (Float, Float) {
        leftDelay[writeIndex] = left
        rightDelay[writeIndex] = right

        let scaledDepth = min(Self.maxDepth, max(0, Double(depth)))
        let wowAmplitude = Self.delayAmplitude(
            deviation: Self.wowDeviation,
            sampleRate: sampleRate,
            rate: Self.wowRate,
            depth: scaledDepth
        )
        let flutterAmplitude = Self.delayAmplitude(
            deviation: Self.flutterDeviation,
            sampleRate: sampleRate,
            rate: Self.flutterRate,
            depth: scaledDepth
        )
        let wowDrift = 1 + 0.2 * sin(wowDriftPhase)
        let wow = sin(wowPhase) * wowAmplitude * wowDrift
        let flutter = sin(flutterPhase) * flutterAmplitude
        let delay = min(Double(leftDelay.count - 4), max(1, baseDelay + wow + flutter))

        let readPosition = wrapped(Double(writeIndex) - delay, count: leftDelay.count)
        let delayedLeft = interpolated(leftDelay, at: readPosition)
        let delayedRight = interpolated(rightDelay, at: readPosition)

        writeIndex += 1
        if writeIndex == leftDelay.count {
            writeIndex = 0
        }

        wowPhase = advance(phase: wowPhase, rate: Self.wowRate)
        flutterPhase = advance(phase: flutterPhase, rate: Self.flutterRate)
        wowDriftPhase = advance(phase: wowDriftPhase, rate: Self.wowDriftRate)
        return (delayedLeft, delayedRight)
    }

    private static func delayAmplitude(deviation: Double, sampleRate: Double, rate: Double, depth: Double) -> Double {
        deviation * depth * sampleRate / (2 * Double.pi * rate)
    }

    private func advance(phase: Double, rate: Double) -> Double {
        var next = phase + 2 * Double.pi * rate / sampleRate
        if next >= 2 * Double.pi {
            next -= 2 * Double.pi
        }
        return next
    }

    private func wrapped(_ value: Double, count: Int) -> Double {
        var result = value
        while result < 0 {
            result += Double(count)
        }
        while result >= Double(count) {
            result -= Double(count)
        }
        return result
    }

    private func interpolated(_ buffer: [Float], at position: Double) -> Float {
        let index1 = Int(floor(position))
        let fraction = Float(position - Double(index1))
        let index0 = wrap(index1 - 1, count: buffer.count)
        let index2 = wrap(index1 + 1, count: buffer.count)
        let index3 = wrap(index1 + 2, count: buffer.count)

        let p0 = buffer[index0]
        let p1 = buffer[index1]
        let p2 = buffer[index2]
        let p3 = buffer[index3]
        let t2 = fraction * fraction
        let t3 = t2 * fraction
        return 0.5 * (
            2 * p1 +
            (-p0 + p2) * fraction +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    private func wrap(_ index: Int, count: Int) -> Int {
        let wrappedIndex = index % count
        return wrappedIndex >= 0 ? wrappedIndex : wrappedIndex + count
    }
}
