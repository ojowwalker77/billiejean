import Foundation

public final class VarispeedResampler: @unchecked Sendable {
    public var rate: Double {
        get { rateValue }
        set { rateValue = Self.clampRate(newValue) }
    }

    private var leftBuffer: [Float]
    private var rightBuffer: [Float]
    private let capacity: Int
    private var writeIndex: Int = 0
    private var writePosition: Int64 = 0
    private var readPosition: Double = 0
    private var rateValue: Double
    private var firstLeft: Float = 0
    private var firstRight: Float = 0
    private var hasFirstSample = false

    public init(sampleRate: Double, rate: Double = 1, capacity: Int? = nil) {
        let minimumCapacity = max(8192, Int(ceil(sampleRate * 2)))
        self.capacity = max(minimumCapacity, capacity ?? minimumCapacity)
        leftBuffer = Array(repeating: 0, count: self.capacity)
        rightBuffer = Array(repeating: 0, count: self.capacity)
        rateValue = Self.clampRate(rate)
    }

    public func reset() {
        writeIndex = 0
        writePosition = 0
        readPosition = 0
        firstLeft = 0
        firstRight = 0
        hasFirstSample = false
    }

    public func push(left: Float, right: Float) {
        if !hasFirstSample {
            firstLeft = left
            firstRight = right
            hasFirstSample = true
        }

        leftBuffer[writeIndex] = left
        rightBuffer[writeIndex] = right
        writeIndex += 1
        if writeIndex == capacity {
            writeIndex = 0
        }
        writePosition += 1
    }

    public func push(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>?,
        frameCount: Int,
        leftStride: Int = 1,
        rightStride: Int = 1
    ) {
        guard frameCount > 0 else {
            return
        }

        for frame in 0..<frameCount {
            let leftSample = left[frame * leftStride]
            let rightSample = right?[frame * rightStride] ?? leftSample
            push(left: leftSample, right: rightSample)
        }
    }

    public func pull(
        intoLeft left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>?,
        maxFrames: Int
    ) -> Int {
        guard maxFrames > 0 else {
            return 0
        }

        var produced = 0
        while produced < maxFrames {
            guard let sample = pullSample() else {
                break
            }
            left[produced] = sample.0
            right?[produced] = sample.1
            produced += 1
        }
        return produced
    }

    public func pullSample() -> (Float, Float)? {
        guard canProduceSample else {
            return nil
        }

        let sample: (Float, Float)
        if isUnityPassthroughPosition {
            let index = Int64(readPosition.rounded())
            sample = (leftSample(at: index), rightSample(at: index))
        } else {
            sample = interpolated(at: readPosition)
        }

        readPosition += rateValue
        return sample
    }

    private var canProduceSample: Bool {
        guard hasFirstSample else {
            return false
        }

        if isUnityPassthroughPosition {
            return Int64(readPosition.rounded()) < writePosition
        }

        return Int64(floor(readPosition)) + 2 < writePosition
    }

    private var isUnityPassthroughPosition: Bool {
        abs(rateValue - 1) < 1e-12 && abs(readPosition.rounded() - readPosition) < 1e-9
    }

    private func interpolated(at position: Double) -> (Float, Float) {
        let index1 = Int64(floor(position))
        let fraction = Float(position - Double(index1))
        let index0 = index1 - 1
        let index2 = index1 + 1
        let index3 = index1 + 2

        return (
            cubic(
                p0: leftSample(at: index0),
                p1: leftSample(at: index1),
                p2: leftSample(at: index2),
                p3: leftSample(at: index3),
                fraction: fraction
            ),
            cubic(
                p0: rightSample(at: index0),
                p1: rightSample(at: index1),
                p2: rightSample(at: index2),
                p3: rightSample(at: index3),
                fraction: fraction
            )
        )
    }

    private func cubic(p0: Float, p1: Float, p2: Float, p3: Float, fraction: Float) -> Float {
        let t2 = fraction * fraction
        let t3 = t2 * fraction
        return 0.5 * (
            2 * p1 +
            (-p0 + p2) * fraction +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    private func leftSample(at position: Int64) -> Float {
        guard position >= 0 else {
            return firstLeft
        }
        return leftBuffer[wrapped(position)]
    }

    private func rightSample(at position: Int64) -> Float {
        guard position >= 0 else {
            return firstRight
        }
        return rightBuffer[wrapped(position)]
    }

    private func wrapped(_ position: Int64) -> Int {
        let index = Int(position % Int64(capacity))
        return index >= 0 ? index : index + capacity
    }

    private static func clampRate(_ value: Double) -> Double {
        min(1, max(0.5, value))
    }
}
