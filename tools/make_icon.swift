import AppKit
import CoreGraphics
import Foundation

// Renders the SmoothyREC app icon: a deep-blue rounded-rect macOS tile with a
// glossy red "record" button centered on it. Everything is drawn in a 1024pt
// design space and scaled to each target pixel size for crisp output.

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func makeIcon(pixelSize S: Int) -> CGImage {
    let dim = CGFloat(S)
    let scale = dim / 1024.0
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: S,
        height: S,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.scaleBy(x: scale, y: scale)

    // --- Dark-navy rounded-rect tile (matches the SmoothyEdit family) ---
    let inset: CGFloat = 64
    let bodyRect = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let radius: CGFloat = 200
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: color(0, 0, 0, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(20, 23, 36))
    ctx.fillPath()
    ctx.restoreGState()

    // Subtle navy vertical gradient (lighter at top), like SmoothyEdit.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let navyGrad = CGGradient(
        colorsSpace: cs,
        colors: [color(36, 42, 64), color(24, 28, 44), color(17, 20, 32)] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        navyGrad,
        start: CGPoint(x: 512, y: 960),
        end: CGPoint(x: 512, y: 64),
        options: []
    )
    ctx.restoreGState()

    // --- Green video-camera glyph (the recorder counterpart to the cup) ---
    // Same flat single-color shape + vertical green gradient as the smoothie.
    let body = CGPath(
        roundedRect: CGRect(x: 238, y: 360, width: 408, height: 304),
        cornerWidth: 66, cornerHeight: 66, transform: nil
    )

    let lens = CGMutablePath()
    lens.move(to: CGPoint(x: 606, y: 400))
    lens.addLine(to: CGPoint(x: 786, y: 452))
    lens.addLine(to: CGPoint(x: 786, y: 572))
    lens.addLine(to: CGPoint(x: 606, y: 624))
    lens.closeSubpath()

    let greenGrad = CGGradient(
        colorsSpace: cs,
        colors: [color(82, 224, 116), color(37, 190, 86)] as CFArray,
        locations: [0.0, 1.0]
    )!
    let greenStart = CGPoint(x: 512, y: 700)
    let greenEnd = CGPoint(x: 512, y: 340)

    // Drop shadow once, under the whole glyph silhouette.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0, 0, 0, 0.30))
    ctx.setFillColor(color(37, 190, 86))
    ctx.addPath(body)
    ctx.addPath(lens)
    ctx.fillPath()
    ctx.restoreGState()

    // Fill body and lens with the identical gradient so they read as one shape.
    for part in [body, lens as CGPath] {
        ctx.saveGState()
        ctx.addPath(part)
        ctx.clip()
        ctx.drawLinearGradient(greenGrad, start: greenStart, end: greenEnd, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // Negative-space lens hole punched back to the navy background — echoes the
    // smoothie cup's cutout detail and reads as the camera lens / record eye.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let lensHole = CGRect(x: 372, y: 442, width: 140, height: 140)
    ctx.addEllipse(in: lensHole)
    ctx.clip()
    ctx.drawLinearGradient(
        navyGrad,
        start: CGPoint(x: 512, y: 960),
        end: CGPoint(x: 512, y: 64),
        options: []
    )
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed for \(url.lastPathComponent)")
    }
    try! data.write(to: url)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

// filename -> pixel size
let targets: [(String, Int)] = [
    ("AppIcon-16.png", 16),
    ("AppIcon-16@2x.png", 32),
    ("AppIcon-32.png", 32),
    ("AppIcon-32@2x.png", 64),
    ("AppIcon-128.png", 128),
    ("AppIcon-128@2x.png", 256),
    ("AppIcon-256.png", 256),
    ("AppIcon-256@2x.png", 512),
    ("AppIcon-512.png", 512),
    ("AppIcon-512@2x.png", 1024),
]

for (name, size) in targets {
    let image = makeIcon(pixelSize: size)
    writePNG(image, to: outDir.appendingPathComponent(name))
    print("wrote \(name) (\(size)px)")
}
