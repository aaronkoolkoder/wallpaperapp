import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import Foundation
import os

/// Keeps the system desktop picture in step with the wallpaper we are rendering.
///
/// macOS derives the menu bar's tint — and the backdrop shown in Mission Control, Stage Manager,
/// and the Spaces switcher — from the desktop picture *file* it has on record, not from whatever
/// is actually composited on screen. Our surface sits below the icons and above the desktop
/// picture, so without this the menu bar keeps tinting for the user's old wallpaper and the
/// illusion falls apart the moment they look up or invoke Mission Control.
///
/// The fix is to hand the system a representative still of what we are playing. It never sees
/// the animation, but everything it derives from the desktop picture is then correct.
@MainActor
public final class DesktopPictureSync {
    private let log = Logger(subsystem: "app.diorama", category: "desktop-picture")
    private let defaults: UserDefaults
    private let fileManager = FileManager.default

    private static let originalKey = "originalDesktopPicture"

    /// Stills exist only so the window server has something to tint the menu bar and Mission
    /// Control from — it scales whatever it is given, and nobody inspects a desktop picture at
    /// 1:1 while a live wallpaper is drawing over it. 2048 is ample for that job and keeps the
    /// decode roughly a quarter the cost of a full 4K frame.
    private static let maximumStillDimension: CGFloat = 2048

    /// Total budget for the still cache. Without a bound this grows once per wallpaper the user
    /// ever sets and is never reclaimed — a large library would leave hundreds of megabytes in
    /// Application Support that nothing cleans up.
    private static let cacheByteBudget: UInt64 = 120 * 1024 * 1024

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Where generated stills live. Kept out of the wallpaper folder, which may be read-only.
    private var cacheDirectory: URL? {
        guard let support = try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let directory = support.appendingPathComponent("Diorama/DesktopStills", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Applying

    /// Derive a still for `contentURL` and make it the system desktop picture on every screen.
    ///
    /// One still per shape of screen, cropped to that shape. Wallpapers are overwhelmingly
    /// 16:9 and displays are not — a 14-inch MacBook Pro is 1.54:1 — and the system does not
    /// reliably honour the scaling asked for below, so a 16:9 still on that display was being
    /// pillarboxed and the bars filled with grey. Our own window covers that almost all of the
    /// time, which is why it showed up as an occasional grey rectangle down one side rather
    /// than as something obviously wrong: at login before the first frame, in the moment
    /// between one wallpaper and the next, and for as long as the app is not running.
    /// - Parameter previewURL: the wallpaper's own preview image, used when the content itself
    ///   is not something that can be decoded into a picture. A scene's content is `scene.pkg`,
    ///   which is an archive: every scene wallpaper was failing to produce a still at all, so
    ///   the menu bar and Mission Control went on tinting for whatever had been playing before.
    public func sync(to contentURL: URL, wallpaperID: String, previewURL: URL? = nil) {
        rememberOriginalIfNeeded()

        for screen in NSScreen.screens {
            let shape = Self.shape(of: screen)
            guard let still = makeStill(
                from: contentURL, wallpaperID: wallpaperID, aspect: shape, previewURL: previewURL
            ) else {
                log.warning("could not derive a still for \(wallpaperID, privacy: .public)")
                continue
            }
            apply(still, to: screen)
        }
    }

    /// A screen's aspect ratio, rounded so that two displays of the same shape share a still.
    nonisolated static func shape(of screen: NSScreen) -> CGFloat {
        let size = screen.frame.size
        guard size.width > 0, size.height > 0 else { return 16.0 / 9 }
        return (size.width / size.height * 100).rounded() / 100
    }

    private func apply(_ url: URL, to screen: NSScreen) {
        // Fill rather than fit: a letterboxed desktop picture would make the menu bar tint from
        // the black bars instead of the image. Asked for, but not depended on — the still is
        // already the shape of this screen, so fitting and filling come to the same thing.
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        } catch {
            log.error("could not set desktop picture: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Recover from an ungraceful exit.
    ///
    /// `restoreOriginal()` runs on quit, but a crash, a force-quit, or a power loss never gets
    /// there — and the user is left with our still as their permanent wallpaper and no obvious
    /// way to connect that to this app. Called at launch: if the picture currently set is one of
    /// ours and we still remember what preceded it, put theirs back before doing anything else.
    ///
    /// Found by killing the app with SIGKILL during benchmarking, which is exactly how a crash
    /// would behave.
    public func reconcileAfterUngracefulExit() {
        guard let screen = NSScreen.main,
              let current = NSWorkspace.shared.desktopImageURL(for: screen),
              let cache = cacheDirectory,
              current.path.hasPrefix(cache.path)
        else { return }

        guard defaults.url(forKey: Self.originalKey) != nil else {
            log.warning("one of our stills is set but no original is remembered; leaving it alone")
            return
        }
        log.info("recovering desktop picture after an ungraceful exit")
        restoreOriginal()
    }

    // MARK: - Restoring

    /// Record what the user had before we touched anything, once.
    private func rememberOriginalIfNeeded() {
        guard defaults.url(forKey: Self.originalKey) == nil,
              let screen = NSScreen.main,
              let current = NSWorkspace.shared.desktopImageURL(for: screen)
        else { return }

        // Do not record one of our own stills as "the original" — that would make the user's
        // real wallpaper unrecoverable if they quit and relaunch.
        if let cache = cacheDirectory, current.path.hasPrefix(cache.path) { return }

        defaults.set(current, forKey: Self.originalKey)
        log.info("remembered original desktop picture")
    }

    /// Put the user's own wallpaper back. Called on quit and when playback stops.
    ///
    /// Not optional politeness: an app that permanently replaces the desktop picture and leaves
    /// it changed after being quit or uninstalled is one the user cannot undo without going
    /// hunting through System Settings.
    public func restoreOriginal() {
        guard let original = defaults.url(forKey: Self.originalKey) else { return }
        guard fileManager.fileExists(atPath: original.path) else {
            log.warning("original desktop picture no longer exists")
            defaults.removeObject(forKey: Self.originalKey)
            return
        }
        // Theirs, put back exactly as it was: no crop, every screen.
        for screen in NSScreen.screens { apply(original, to: screen) }
        defaults.removeObject(forKey: Self.originalKey)
        log.info("restored original desktop picture")
    }

    // MARK: - Still generation

    private func makeStill(
        from contentURL: URL, wallpaperID: String, aspect: CGFloat, previewURL: URL?
    ) -> URL? {
        guard let cacheDirectory else { return nil }
        // The shape is part of the identity: the same wallpaper on a 16:9 display and on a
        // 1.54:1 one needs two different crops.
        let destination = cacheDirectory.appendingPathComponent(
            "\(wallpaperID)@\(Int((aspect * 100).rounded())).heic"
        )

        // Stills are deterministic for a given wallpaper, so a cache hit skips video decoding
        // entirely on every subsequent switch.
        if fileManager.fileExists(atPath: destination.path) {
            touch(destination)
            return destination
        }

        // Explicit autorelease pool. Decoding a 4K video frame and downscaling it allocates
        // tens of megabytes of CoreGraphics buffers, and on a main-actor Task there is no pool
        // boundary to drain them — they accumulate for the life of the process. Measured at
        // +108MB resident across a handful of wallpapers before this was added.
        let written: Bool = autoreleasepool {
            let fromContent: NSImage? = Self.isVideo(contentURL)
                ? videoFrame(from: contentURL)
                : NSImage(contentsOf: contentURL)
            guard let image = Self.picture(fromContent: fromContent, preview: previewURL) else {
                return false
            }
            return write(image, to: destination, aspect: aspect)
        }

        guard written else { return nil }
        pruneCache()
        return destination
    }

    /// Write a downscaled HEIC.
    ///
    /// PNG at source resolution was costing several megabytes per wallpaper — a 4K video frame
    /// stored losslessly for something the window server only ever shows as a background. HEIC
    /// at high quality is roughly an order of magnitude smaller with no visible difference at
    /// desktop-picture scale.
    private func write(_ image: NSImage, to url: URL, aspect: CGFloat) -> Bool {
        guard var cgImage = image.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ) else { return false }

        if let cropped = Self.cropped(cgImage, to: aspect) { cgImage = cropped }

        let longest = CGFloat(max(cgImage.width, cgImage.height))
        if longest > Self.maximumStillDimension, let scaled = downscale(
            cgImage, factor: Self.maximumStillDimension / longest
        ) {
            cgImage = scaled
        }

        // HEIC where supported, JPEG otherwise; neither is lossless, which is the point.
        for type in [UTType.heic, UTType.jpeg] {
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type.identifier as CFString, 1, nil
            ) else { continue }
            CGImageDestinationAddImage(
                destination, cgImage,
                [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
            )
            if CGImageDestinationFinalize(destination) { return true }
        }
        log.error("could not write still to \(url.lastPathComponent, privacy: .public)")
        return false
    }

    /// The middle of `image` at the given aspect ratio, or nil when it is already that shape.
    ///
    /// The same crop the window server would make if it filled the screen with this picture,
    /// made here instead so that it cannot decide to letterbox it rather than fill it.
    nonisolated static func cropped(_ image: CGImage, to aspect: CGFloat) -> CGImage? {
        guard aspect > 0, image.width > 0, image.height > 0 else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let current = width / height
        guard abs(current - aspect) > 0.01 else { return nil }

        let box = current > aspect
            ? CGSize(width: (height * aspect).rounded(.down), height: height)
            : CGSize(width: width, height: (width / aspect).rounded(.down))
        guard box.width >= 1, box.height >= 1 else { return nil }

        return image.cropping(to: CGRect(
            x: ((width - box.width) / 2).rounded(.down),
            y: ((height - box.height) / 2).rounded(.down),
            width: box.width, height: box.height
        ))
    }

    private func downscale(_ image: CGImage, factor: CGFloat) -> CGImage? {
        autoreleasepool {
            downscaleInner(image, factor: factor)
        }
    }

    private func downscaleInner(_ image: CGImage, factor: CGFloat) -> CGImage? {
        let width = Int(CGFloat(image.width) * factor)
        let height = Int(CGFloat(image.height) * factor)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Evict least-recently-used stills once the cache exceeds its budget.
    private func pruneCache() {
        guard let cacheDirectory,
              let contents = try? fileManager.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.contentAccessDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              )
        else { return }

        let entries = contents.compactMap { url -> (URL, Date, UInt64)? in
            guard let values = try? url.resourceValues(
                forKeys: [.contentAccessDateKey, .fileSizeKey]
            ) else { return nil }
            return (url, values.contentAccessDate ?? .distantPast, UInt64(values.fileSize ?? 0))
        }

        var total = entries.reduce(UInt64(0)) { $0 + $1.2 }
        guard total > Self.cacheByteBudget else { return }

        // Oldest access first.
        for (url, _, size) in entries.sorted(by: { $0.1 < $1.1 }) {
            guard total > Self.cacheByteBudget else { break }
            // Never evict the still currently set as the desktop picture.
            if NSScreen.screens.contains(where: {
                NSWorkspace.shared.desktopImageURL(for: $0) == url
            }) { continue }
            try? fileManager.removeItem(at: url)
            total -= size
        }
        log.info("pruned desktop still cache to \(total / 1_048_576)MB")
    }

    /// Refresh the access date so the LRU ordering reflects real use.
    private func touch(_ url: URL) {
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    /// Pull a frame from a little way in. The first frame of a video wallpaper is often a fade
    /// from black, which would tint the menu bar for a colour the user never actually sees.
    ///
    /// Uses the async generator and waits on it. The synchronous `copyCGImage` is deprecated,
    /// and this runs once per wallpaper on a cache miss rather than on any hot path, so blocking
    /// briefly here is cheaper than restructuring the caller to be async.
    /// Whether a frame has to be decoded out of this file rather than read from it.
    nonisolated static func isVideo(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v", "webm", "mkv", "avi"].contains(url.pathExtension.lowercased())
    }

    /// The picture to hand the window server: the content itself, or the wallpaper's preview
    /// when the content is not a picture at all.
    ///
    /// A scene's content is `scene.pkg`, an archive, and a web wallpaper's is markup. Neither
    /// decodes, so every scene and web wallpaper produced no still — and the menu bar and
    /// Mission Control went on tinting for whatever had been playing before, which is the exact
    /// thing this type exists to prevent.
    nonisolated static func picture(fromContent content: NSImage?, preview: URL?) -> NSImage? {
        if let content { return content }
        return preview.flatMap { NSImage(contentsOf: $0) }
    }

    private func videoFrame(from url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        // Cap the decode itself rather than decoding full size and shrinking afterwards.
        // Workshop video wallpapers are routinely 4K, and a full-resolution frame is ~33MB of
        // CoreGraphics buffer per wallpaper — measured at +105MB resident across a handful of
        // them, which is a real spike the first time someone browses a large library. Asking
        // AVFoundation for a bounded size never allocates that buffer at all.
        generator.maximumSize = CGSize(
            width: Self.maximumStillDimension, height: Self.maximumStillDimension
        )

        func frame(at seconds: Double) -> CGImage? {
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: CGImage?
            generator.generateCGImageAsynchronously(
                for: CMTime(seconds: seconds, preferredTimescale: 600)
            ) { image, _, _ in
                result = image
                semaphore.signal()
            }
            // Bounded wait: a malformed video must not hang the caller forever.
            _ = semaphore.wait(timeout: .now() + 5)
            return result
        }

        // Retry at zero for videos shorter than the offset.
        if let image = frame(at: 2) ?? frame(at: 0) {
            return NSImage(cgImage: image, size: .zero)
        }
        return nil
    }

}
