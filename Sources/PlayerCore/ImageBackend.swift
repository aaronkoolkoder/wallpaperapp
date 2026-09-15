import AppKit
import Diagnostics
import Foundation
import WallpaperKit
import os

/// Plays still images and animated GIFs.
///
/// The cheapest backend by a wide margin: a still image is handed to the compositor once and
/// costs literally nothing thereafter, with no display link and no per-frame work. Animated GIFs
/// are driven by Core Animation's own keyframe timing rather than a timer we own.
@MainActor
public final class ImageBackend: WallpaperBackend {
    public static let kind: WallpaperKind = .image

    public private(set) var contentFrameRate: Int?
    public private(set) var report: CompatibilityReport

    private var hostView: NSView?
    private let log = Logger(subsystem: "app.diorama", category: "image")

    public init() {
        report = CompatibilityReport(wallpaperID: "")
    }

    public func start(_ request: WallpaperRequest, on surface: DesktopSurface) throws {
        stop()
        report = CompatibilityReport(wallpaperID: request.id)

        guard FileManager.default.fileExists(atPath: request.contentURL.path) else {
            throw BackendError.contentMissing(request.contentURL)
        }
        guard let image = NSImage(contentsOf: request.contentURL) else {
            throw BackendError.contentUnreadable(
                request.contentURL, underlying: "not a format macOS can decode"
            )
        }

        let imageView = NSImageView(frame: .zero)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.wantsLayer = true
        imageView.layer?.contentsGravity = .resizeAspectFill

        hostView = imageView
        surface.mount(imageView)

        // A still image needs no display link at all. Reporting a frame rate of nil and never
        // drawing again is the correct behaviour, and is why this backend is effectively free.
        contentFrameRate = nil
        log.info("showing \(request.contentURL.lastPathComponent, privacy: .public)")
    }

    public func stop() {
        (hostView as? NSImageView)?.image = nil
        hostView = nil
    }

    public func setPaused(_ paused: Bool) {
        (hostView as? NSImageView)?.animates = !paused
    }
}
