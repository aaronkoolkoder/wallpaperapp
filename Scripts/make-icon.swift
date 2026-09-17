import AppKit
import CoreGraphics
import Foundation

// Generates the app icon set.
//
// Drawn in code rather than shipped as a binary asset so it stays in step with the app's palette
// and can be regenerated at any size. The motif is a stack of layers over a night gradient —
// what a scene wallpaper actually is — rather than a literal picture frame.

func drawIcon(size: CGFloat, context: CGContext) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.clear(rect)

    // macOS icons sit inside a rounded square with generous padding rather than filling the
    // canvas; the system adds no shape of its own.
    let inset = size * 0.0834
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = body.width * 0.2237
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // Night gradient, matching the Space Black surfaces in the app.
    let colors = [
        CGColor(red: 0.055, green: 0.063, blue: 0.118, alpha: 1),
        CGColor(red: 0.129, green: 0.149, blue: 0.290, alpha: 1),
        CGColor(red: 0.231, green: 0.278, blue: 0.451, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.midX, y: body.maxY),
            end: CGPoint(x: body.midX, y: body.minY),
            options: []
        )
    }

    // A scatter of stars, seeded so every regeneration is identical.
    var seed: UInt64 = 0x5EED
    func random() -> CGFloat {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat((seed >> 33) % 10_000) / 10_000
    }
    for _ in 0 ..< 46 {
        let x = body.minX + random() * body.width
        let y = body.minY + body.height * 0.34 + random() * body.height * 0.66
        let r = size * (0.004 + random() * 0.0075)
        context.setFillColor(CGColor(gray: 1, alpha: 0.35 + random() * 0.55))
        context.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
    }

    // Layered hills: the "stack of scenes" idea, and it reads at 16pt where finer detail does not.
    let layers: [(y: CGFloat, amp: CGFloat, color: CGColor)] = [
        (0.42, 0.055, CGColor(red: 0.118, green: 0.192, blue: 0.318, alpha: 1)),
        (0.30, 0.070, CGColor(red: 0.078, green: 0.137, blue: 0.239, alpha: 1)),
        (0.17, 0.085, CGColor(red: 0.043, green: 0.086, blue: 0.161, alpha: 1)),
    ]
    for layer in layers {
        let path = CGMutablePath()
        let baseY = body.minY + body.height * layer.y
        path.move(to: CGPoint(x: body.minX, y: body.minY))
        path.addLine(to: CGPoint(x: body.minX, y: baseY))
        var x = body.minX
        while x <= body.maxX {
            let t = (x - body.minX) / body.width
            let y = baseY + sin(t * .pi * 2.1 + layer.y * 9) * body.height * layer.amp
            path.addLine(to: CGPoint(x: x, y: y))
            x += body.width / 60
        }
        path.addLine(to: CGPoint(x: body.maxX, y: body.minY))
        path.closeSubpath()
        context.setFillColor(layer.color)
        context.addPath(path)
        context.fillPath()
    }

    // Moon.
    let moonRadius = body.width * 0.105
    let moonCentre = CGPoint(x: body.minX + body.width * 0.71, y: body.minY + body.height * 0.735)
    context.setFillColor(CGColor(red: 1, green: 0.973, blue: 0.898, alpha: 1))
    context.fillEllipse(
        in: CGRect(
            x: moonCentre.x - moonRadius, y: moonCentre.y - moonRadius,
            width: moonRadius * 2, height: moonRadius * 2
        )
    )

    context.restoreGState()
}

func writePNG(size: Int, to url: URL) {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    drawIcon(size: CGFloat(size), context: context)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
          ) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let outputRoot = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = outputRoot.appendingPathComponent("Diorama.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The exact set `iconutil` expects; a missing size makes it refuse the whole set.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    writePNG(size: variant.size, to: iconset.appendingPathComponent("\(variant.name).png"))
}
// A standalone copy for the DMG window and the marketing site.
writePNG(size: 1024, to: outputRoot.appendingPathComponent("icon-1024.png"))
print("wrote \(iconset.path)")
