import Foundation

public enum StereoWidth {
    public static func apply(left: Float, right: Float, width: Float) -> (Float, Float) {
        let mid = (left + right) * 0.5
        let side = (left - right) * 0.5 * width
        return (mid + side, mid - side)
    }
}
