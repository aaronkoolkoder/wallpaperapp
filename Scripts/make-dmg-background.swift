import AppKit
import CoreGraphics
import Foundation

// Background art for the installer window.
//
// Drawn at 2x and paired with a 1x copy so the window looks right on both Retina and
// non-Retina displays; a DMG background is one of the last places a blurry asset still shows up.

let width: CGFloat = 660
let height: CGFloat = 420

// Where the two icons sit. The arrow is drawn to match, so these must agree with the layout
// written into the .DS_Store — a background whose arrow points somewhere the icon is not is
// worse than no background at all.
let appCentre = CGPoint(x: 172, y: 188)
let applicationsCentre = CGPoint(x: 488, y: 188)

func draw(scale: CGFloat, to url: URL) {
    let pixelWidth = Int(width * scale)
    let pixelHeight = Int(height * scale)
    guard let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }

    context.scaleBy(x: scale, y: scale)

    // Deep neutral, matching the app's own base surface.
    let colors = [
        CGColor(red: 0.071, green: 0.071, blue: 0.078, alpha: 1),
        CGColor(red: 0.118, green: 0.125, blue: 0.149, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: []
        )
    }

    // Arrow between the two icon positions, stopping well short of each so it never sits under
    // an icon or its label.
    let inset: CGFloat = 78
    let start = CGPoint(x: appCentre.x + inset, y: appCentre.y + 6)
    let end = CGPoint(x: applicationsCentre.x - inset, y: applicationsCentre.y + 6)

    context.setStrokeColor(CGColor(gray: 1, alpha: 0.30))
    context.setLineWidth(2.5)
    context.setLineCap(.round)
    context.setLineDash(phase: 0, lengths: [9, 9])
    context.move(to: start)
    context.addLine(to: CGPoint(x: end.x - 14, y: end.y))
    context.strokePath()

    context.setLineDash(phase: 0, lengths: [])
    context.setFillColor(CGColor(gray: 1, alpha: 0.45))
    context.move(to: end)
    context.addLine(to: CGPoint(x: end.x - 16, y: end.y - 9))
    context.addLine(to: CGPoint(x: end.x - 16, y: end.y + 9))
    context.closePath()
    context.fillPath()

    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics

    func text(
        _ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat,
        centredAt y: CGFloat, tracking: CGFloat = 0
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: alpha),
            .paragraphStyle: paragraph,
            .kern: tracking,
        ])
        attributed.draw(with: CGRect(x: 0, y: y, width: width, height: size * 1.6),
                        options: [.usesLineFragmentOrigin])
    }

    text("Drag Diorama into Applications", size: 19, weight: .semibold, alpha: 0.92, centredAt: 330)
    text("Live wallpapers for macOS", size: 13, weight: .regular, alpha: 0.46, centredAt: 302)
    text(
        "FIRST LAUNCH: RIGHT-CLICK THE APP AND CHOOSE OPEN",
        size: 10, weight: .semibold, alpha: 0.34, centredAt: 52, tracking: 0.8
    )

    NSGraphicsContext.restoreGraphicsState()

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
          ) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
draw(scale: 1, to: root.appendingPathComponent("dmg-background.png"))
draw(scale: 2, to: root.appendingPathComponent("dmg-background@2x.png"))
print("wrote DMG background")
