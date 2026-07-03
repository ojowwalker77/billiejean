import CoreImage
import CoreGraphics
import Foundation

public enum ArtworkColor {
    /// Dominant vibrant color of the artwork, as sRGB components 0...1.
    /// Strategy: downscale to ~24x24, compute the average of the most saturated
    /// quartile of pixels (fallback: plain average), then clamp brightness into
    /// 0.25...0.8 so the color works as a gradient base.
    public static func dominant(from pngData: Data) -> (red: Double, green: Double, blue: Double)? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CIImage(data: pngData, options: [.colorSpace: colorSpace]) else {
            return nil
        }

        let width = 24
        let height = 24
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else {
            return nil
        }

        let normalized = image.transformed(
            by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        )
        let scaled = normalized.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(width) / extent.width,
                y: CGFloat(height) / extent.height
            )
        )
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ])
        context.render(
            scaled,
            toBitmap: &pixels,
            rowBytes: bytesPerRow,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        var samples: [PixelSample] = []
        samples.reserveCapacity(width * height)

        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0 else {
                continue
            }

            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            samples.append(PixelSample(red: red, green: green, blue: blue))
        }

        guard !samples.isEmpty else {
            return nil
        }

        let sortedBySaturation = samples.sorted { lhs, rhs in
            lhs.saturation > rhs.saturation
        }
        let quartileCount = max(1, sortedBySaturation.count / 4)
        let vibrantSamples = Array(sortedBySaturation.prefix(quartileCount))
        let averageSource = vibrantSamples.contains { $0.saturation > 0.01 } ? vibrantSamples : samples
        let averaged = average(averageSource)
        return clampBrightness(red: averaged.red, green: averaged.green, blue: averaged.blue)
    }

    private static func average(_ samples: [PixelSample]) -> PixelSample {
        let totals = samples.reduce((red: 0.0, green: 0.0, blue: 0.0)) { partial, sample in
            (
                red: partial.red + sample.red,
                green: partial.green + sample.green,
                blue: partial.blue + sample.blue
            )
        }

        let count = Double(samples.count)
        return PixelSample(red: totals.red / count, green: totals.green / count, blue: totals.blue / count)
    }

    private static func clampBrightness(red: Double, green: Double, blue: Double) -> (red: Double, green: Double, blue: Double) {
        let brightness = max(red, green, blue)
        let clampedBrightness = min(0.8, max(0.25, brightness))

        guard brightness > 0 else {
            return (clampedBrightness, clampedBrightness, clampedBrightness)
        }

        let scale = clampedBrightness / brightness
        return (
            red: min(1, max(0, red * scale)),
            green: min(1, max(0, green * scale)),
            blue: min(1, max(0, blue * scale))
        )
    }
}

private struct PixelSample {
    let red: Double
    let green: Double
    let blue: Double

    var saturation: Double {
        let high = max(red, green, blue)
        let low = min(red, green, blue)

        guard high > 0 else {
            return 0
        }

        return (high - low) / high
    }
}
