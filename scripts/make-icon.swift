// Generates AppIcon.icns for billiejean: a vinyl record with an amber label on
// a dark rounded-rect background, drawn with CoreGraphics at every icon size.
// Run: swift scripts/make-icon.swift  (writes scripts/AppIcon.icns via iconutil)
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let s = size
    // macOS icon grid: content inset ~10%, continuous-corner squircle ~22.4%.
    let inset = s * 0.10
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.224, yRadius: rect.width * 0.224)
    NSColor(srgbRed: 0.086, green: 0.075, blue: 0.066, alpha: 1).setFill() // #161311
    bg.fill()

    // Vinyl disc
    let discD = rect.width * 0.78
    let discRect = CGRect(
        x: rect.midX - discD / 2, y: rect.midY - discD / 2,
        width: discD, height: discD
    )
    ctx.saveGState()
    ctx.addEllipse(in: discRect)
    ctx.clip()
    let colors = [
        NSColor(srgbRed: 0.10, green: 0.07, blue: 0.05, alpha: 1).cgColor,
        NSColor(srgbRed: 0.45, green: 0.25, blue: 0.12, alpha: 1).cgColor,
        NSColor(srgbRed: 0.69, green: 0.39, blue: 0.18, alpha: 1).cgColor, // amber #B0642F
        NSColor(srgbRed: 0.30, green: 0.17, blue: 0.08, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: colors, locations: [0.18, 0.45, 0.75, 1.0]
    ) {
        ctx.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: discRect.midX, y: discRect.midY), startRadius: 0,
            endCenter: CGPoint(x: discRect.midX, y: discRect.midY), endRadius: discD / 2,
            options: []
        )
    }
    // Grooves
    ctx.setLineWidth(max(0.5, s / 512))
    for i in 0..<9 {
        let f = 0.42 + CGFloat(i) * 0.062
        let r = discD / 2 * f
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.strokeEllipse(in: CGRect(
            x: discRect.midX - r, y: discRect.midY - r, width: r * 2, height: r * 2
        ))
    }
    ctx.restoreGState()

    // Label
    let labelD = discD * 0.36
    let labelRect = CGRect(
        x: discRect.midX - labelD / 2, y: discRect.midY - labelD / 2,
        width: labelD, height: labelD
    )
    NSColor(srgbRed: 0.91, green: 0.64, blue: 0.29, alpha: 1).setFill() // #E8A34A
    ctx.fillEllipse(in: labelRect)
    NSColor(srgbRed: 0.165, green: 0.149, blue: 0.129, alpha: 1).setFill()
    let holeD = labelD * 0.12
    ctx.fillEllipse(in: CGRect(
        x: discRect.midX - holeD / 2, y: discRect.midY - holeD / 2,
        width: holeD, height: holeD
    ))

    // Sheen
    ctx.saveGState()
    ctx.addEllipse(in: discRect)
    ctx.clip()
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    ctx.rotate(by: 0)
    let sheen = CGMutablePath()
    sheen.move(to: CGPoint(x: discRect.midX, y: discRect.midY))
    sheen.addArc(
        center: CGPoint(x: discRect.midX, y: discRect.midY),
        radius: discD / 2, startAngle: .pi * 0.30, endAngle: .pi * 0.46, clockwise: false
    )
    sheen.closeSubpath()
    ctx.addPath(sheen)
    ctx.fillPath()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

let iconsetURL = URL(fileURLWithPath: "scripts/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
    (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in sizes {
    let img = drawIcon(size: CGFloat(px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { continue }
    rep.size = NSSize(width: px, height: px)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: iconsetURL.appendingPathComponent("\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "scripts/AppIcon.iconset", "-o", "scripts/AppIcon.icns"]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetURL)
print(task.terminationStatus == 0 ? "Wrote scripts/AppIcon.icns" : "iconutil failed")
