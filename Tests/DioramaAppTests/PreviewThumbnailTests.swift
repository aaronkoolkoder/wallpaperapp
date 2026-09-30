import AppKit
import Foundation
import Testing
@testable import DioramaApp

@Suite("PreviewThumbnails")
@MainActor
struct PreviewThumbnailTests {

    /// Writes a deliberately oversized PNG, the way a 4K wallpaper preview is oversized.
    private func makeLargePNG(side: Int = 2000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaPreview-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        return url
    }

    @Test("A preview is decoded down to the size it is drawn at")
    func downsamples() async throws {
        // The point of the whole type. A real library had 113 previews totalling 62 MB, several
        // of them animated GIFs over a megabyte; decoding those at full size on the main thread
        // is what made the grid unusable.
        let url = try makeLargePNG()
        defer { try? FileManager.default.removeItem(at: url) }

        let thumbnail = try #require(await PreviewThumbnails.shared.load(url, maxPixel: 100))
        #expect(max(thumbnail.size.width, thumbnail.size.height) <= 100)
        #expect(thumbnail.size.width > 0)
    }

    @Test("A second request is served from cache rather than decoded again")
    func caches() async throws {
        let url = try makeLargePNG(side: 800)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(PreviewThumbnails.shared.cached(url) == nil)
        let before = PreviewThumbnails.shared.decodeCount
        _ = await PreviewThumbnails.shared.load(url, maxPixel: 120)
        _ = await PreviewThumbnails.shared.load(url, maxPixel: 120)
        // A card redraws constantly while scrolling; without this every redraw is a decode.
        // Counted rather than read back out of the cache: `NSCache` evicts whenever it likes,
        // so asserting the entry is still there fails on a machine under memory pressure and
        // says nothing about this type.
        #expect(PreviewThumbnails.shared.decodeCount - before == 1)
    }

    @Test("A file that is not an image returns nothing rather than throwing")
    func handlesGarbage() async throws {
        // Workshop folders contain whatever their author put there.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaPreview-\(UUID().uuidString).jpg")
        try Data("this is not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await PreviewThumbnails.shared.load(url, maxPixel: 100) == nil)
    }

    @Test("A missing file returns nothing")
    func handlesMissingFile() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaPreview-does-not-exist.png")
        #expect(await PreviewThumbnails.shared.load(url, maxPixel: 100) == nil)
    }
}
