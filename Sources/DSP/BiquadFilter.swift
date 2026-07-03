import Foundation

public struct BiquadFilter: Sendable {
    private var b0: Float = 1
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var z1: Float = 0
    private var z2: Float = 0

    public init() {}

    public init(b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) {
        let invA0 = 1 / a0
        self.b0 = b0 * invA0
        self.b1 = b1 * invA0
        self.b2 = b2 * invA0
        self.a1 = a1 * invA0
        self.a2 = a2 * invA0
    }

    public mutating func process(_ sample: Float) -> Float {
        let out = b0 * sample + z1
        z1 = b1 * sample - a1 * out + z2
        z2 = b2 * sample - a2 * out
        return out
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }

    public static func lowPass(sampleRate: Double, cutoff: Double, q: Double = 0.707) -> BiquadFilter {
        make(sampleRate: sampleRate, cutoff: cutoff, q: q) { cosW0, alpha in
            let b0 = (1 - cosW0) / 2
            let b1 = 1 - cosW0
            let b2 = (1 - cosW0) / 2
            let a0 = 1 + alpha
            let a1 = -2 * cosW0
            let a2 = 1 - alpha
            return (b0, b1, b2, a0, a1, a2)
        }
    }

    public static func highPass(sampleRate: Double, cutoff: Double, q: Double = 0.707) -> BiquadFilter {
        make(sampleRate: sampleRate, cutoff: cutoff, q: q) { cosW0, alpha in
            let b0 = (1 + cosW0) / 2
            let b1 = -(1 + cosW0)
            let b2 = (1 + cosW0) / 2
            let a0 = 1 + alpha
            let a1 = -2 * cosW0
            let a2 = 1 - alpha
            return (b0, b1, b2, a0, a1, a2)
        }
    }

    public static func lowShelf(sampleRate: Double, cutoff: Double, gainDB: Double) -> BiquadFilter {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let sinW0 = sin(w0)
        let cosW0 = cos(w0)
        let sqrtA = sqrt(a)
        let alpha = sinW0 / 2 * sqrt(2)

        let b0 = a * ((a + 1) - (a - 1) * cosW0 + 2 * sqrtA * alpha)
        let b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
        let b2 = a * ((a + 1) - (a - 1) * cosW0 - 2 * sqrtA * alpha)
        let a0 = (a + 1) + (a - 1) * cosW0 + 2 * sqrtA * alpha
        let a1 = -2 * ((a - 1) + (a + 1) * cosW0)
        let a2 = (a + 1) + (a - 1) * cosW0 - 2 * sqrtA * alpha
        return BiquadFilter(
            b0: Float(b0), b1: Float(b1), b2: Float(b2),
            a0: Float(a0), a1: Float(a1), a2: Float(a2)
        )
    }

    private static func make(
        sampleRate: Double,
        cutoff: Double,
        q: Double,
        coefficients: (Double, Double) -> (Double, Double, Double, Double, Double, Double)
    ) -> BiquadFilter {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let c = coefficients(cosW0, alpha)
        return BiquadFilter(
            b0: Float(c.0), b1: Float(c.1), b2: Float(c.2),
            a0: Float(c.3), a1: Float(c.4), a2: Float(c.5)
        )
    }
}
