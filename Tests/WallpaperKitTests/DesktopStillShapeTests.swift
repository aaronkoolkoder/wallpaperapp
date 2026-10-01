import AppKit
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WallpaperKit

/// The still handed to the window server has to be the shape of the screen it is set on.
///
/// macOS derives the menu bar tint and the Mission Control backdrop from the desktop picture
/// file, and it is also what shows through whenever our own window is not covering it — at
/// login before the first frame, between one wallpaper and the next, and whenever the app is
/// not running. Wallpapers are overwhelmingly 16:9 and displays are not: a 14-inch MacBook Pro
/// is 1.54:1. The system does not reliably honour the "fill, clipping allowed" it is asked for,
/// so a 16:9 still on that display came back pillarboxed with grey bars down the sides.
@Suite("Desktop still shape")
struct DesktopStillShapeTests {

    private func image(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }

    @Test("A 16:9 still is cropped to the shape of the display it goes on")
    func cropsToTheScreen() throws {
        // 3024x1964, the display this was found on.
        let cropped = try #require(DesktopPictureSync.cropped(image(1920, 1080), to: 1.54))
        #expect(cropped.height == 1080, "the full height is kept")
        #expect(cropped.width == 1663, "and the width comes in to match the screen")
        let shape = CGFloat(cropped.width) / CGFloat(cropped.height)
        #expect(abs(shape - 1.54) < 0.01, "cropped to \(shape):1")
    }

    @Test("A still taller than the screen is cropped the other way")
    func cropsTallImages() throws {
        let cropped = try #require(DesktopPictureSync.cropped(image(1080, 1920), to: 1.54))
        #expect(cropped.width == 1080, "the full width is kept")
        #expect(cropped.height == 701)
    }

    @Test("A still already the right shape is left alone")
    func leavesMatchingImages() {
        // Nil rather than a copy: cropping a 3024x1964 still to 1.54 would cost a full
        // re-encode of every desktop picture for nothing.
        #expect(DesktopPictureSync.cropped(image(3024, 1964), to: 1.54) == nil)
        #expect(DesktopPictureSync.cropped(image(1920, 1080), to: 16.0 / 9) == nil)
    }

    @Test("Nonsense never produces a nonsense crop")
    func refusesNonsense() {
        #expect(DesktopPictureSync.cropped(image(1920, 1080), to: 0) == nil)
        #expect(DesktopPictureSync.cropped(image(1920, 1080), to: -2) == nil)
        // An extreme shape still leaves at least one pixel to encode.
        let sliver = DesktopPictureSync.cropped(image(1920, 1080), to: 5000)
        #expect(sliver == nil || sliver!.height >= 1)
    }

    /// A scene's content is `scene.pkg` and a web wallpaper's is `index.html`. Neither is a
    /// picture, so neither produced a still at all, and the menu bar went on tinting for
    /// whatever had been playing before — the one thing this type exists to prevent.
    @Test("A wallpaper whose content is not a picture falls back to its preview")
    func fallsBackToThePreview() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaStill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let preview = directory.appendingPathComponent("preview.png")
        let destination = try #require(CGImageDestinationCreateWithURL(
            preview as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image(640, 360), nil)
        #expect(CGImageDestinationFinalize(destination))

        // An archive decodes to nothing, so the preview stands in for it.
        let fallback = DesktopPictureSync.picture(fromContent: nil, preview: preview)
        #expect(fallback != nil)
        #expect(fallback?.size.width == 640)

        // Content that does decode is still preferred over the preview.
        let fromContent = NSImage(size: NSSize(width: 10, height: 10))
        #expect(DesktopPictureSync.picture(fromContent: fromContent, preview: preview)?.size.width == 10)

        // And nothing at all stays nothing, rather than a blank desktop picture.
        #expect(DesktopPictureSync.picture(fromContent: nil, preview: nil) == nil)
    }

    @Test("A video's still is decoded from the video, not read as one")
    func recognisesVideos() {
        #expect(DesktopPictureSync.isVideo(URL(fileURLWithPath: "/w/scene.mp4")))
        #expect(DesktopPictureSync.isVideo(URL(fileURLWithPath: "/w/Scene.MOV")))
        #expect(!DesktopPictureSync.isVideo(URL(fileURLWithPath: "/w/scene.pkg")))
        #expect(!DesktopPictureSync.isVideo(URL(fileURLWithPath: "/w/index.html")))
    }
}
