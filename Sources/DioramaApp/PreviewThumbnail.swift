import AppKit
import ImageIO
import SwiftUI
import os

/// Decodes wallpaper previews off the main thread, at the size they are actually drawn.
///
/// The naive version — `NSImage(contentsOf:)` inline in a card's body — decodes the full image
/// synchronously on the main thread, and again on every redraw. A real library made that
/// untenable: 113 previews totalling 62 MB, averaging half a megabyte, several of them animated
/// GIFs over a megabyte each. A grid of those hangs while it scrolls and holds every
/// full-resolution bitmap in memory at once.
///
/// `CGImageSourceCreateThumbnailAtIndex` decodes *at* the target size rather than decoding and
/// then shrinking, which is the difference that matters for a 4K JPEG behind a 300-point card.
@MainActor
final class PreviewThumbnails {
    static let shared = PreviewThumbnails()

    /// Bounded by total pixels rather than count: a hundred small previews cost less than ten
    /// large ones, and counting entries would evict the wrong things.
    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private let queue = DispatchQueue(
        label: "app.diorama.thumbnails", qos: .userInitiated, attributes: .concurrent
    )
    private let log = Logger(subsystem: "app.diorama", category: "thumbnails")

    private init() {}

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    /// Loads `url` downsampled to at most `maxPixel` on its long edge.
    func load(_ url: URL, maxPixel: Int) async -> NSImage? {
        if let hit = cached(url) { return hit }

        let image: NSImage? = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.thumbnail(at: url, maxPixel: maxPixel))
            }
        }

        guard let image else { return nil }
        let cost = Int(image.size.width * image.size.height) * 4
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    /// - Note: `nonisolated` and pure, so it can run on the loading queue.
    nonisolated private static func thumbnail(at url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Honours EXIF orientation and decodes straight to this size.
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }

        return NSImage(
            cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

/// A wallpaper preview, loaded asynchronously and downsampled.
///
/// Shows the type's symbol until the image arrives, rather than an empty box that pops — a grid
/// of blanks filling in at random reads as broken.
struct PreviewImage: View {
    @Environment(\.isOffscreenRendering) private var isOffscreenRendering
    let url: URL?
    let fallbackSymbol: String
    var maxPixel: Int = 700

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url else { return }
            // Synchronous only for the offscreen interface renderer, which captures a single
            // frame and would otherwise photograph the placeholder.
            if isOffscreenRendering {
                image = PreviewThumbnails.shared.cached(url)
                    ?? NSImage(contentsOf: url)
                return
            }
            image = await PreviewThumbnails.shared.load(url, maxPixel: maxPixel)
        }
    }

    private var placeholder: some View {
        ZStack {
            Design.Surface.inset
            Image(systemName: fallbackSymbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Design.Ink.tertiary)
        }
    }
}
