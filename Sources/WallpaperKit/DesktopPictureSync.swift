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
    public func sync(to contentURL: URL, wallpaperID: String) {
        rememberOriginalIfNeeded()

        guard let still = makeStill(from: contentURL, wallpaperID: wallpaperID) else {
            log.warning("could not derive a still for \(wallpaperID, privacy: .public)")
            return
        }
        apply(still)
    }

    private func apply(_ url: URL) {
        // Fill rather than fit: a letterboxed desktop picture would make the menu bar tint from
        // the black bars instead of the image.
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            } catch {
                log.error("could not set desktop picture: \(error.localizedDescription, privacy: .public)")
            }
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
        apply(original)
        defaults.removeObject(forKey: Self.originalKey)
        log.info("restored original desktop picture")
    }

    // MARK: - Still generation

    private func makeStill(from contentURL: URL, wallpaperID: String) -> URL? {
        guard let cacheDirectory else { return nil }
        let destination = cacheDirectory.appendingPathComponent("\(wallpaperID).heic")

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
            let image: NSImage? = switch contentURL.pathExtension.lowercased() {
            case "mp4", "mov", "m4v", "webm", "mkv", "avi":
                videoFrame(from: contentURL)
            default:
                NSImage(contentsOf: contentURL)
            }
            guard let image else { return false }
            return write(image, to: destination)
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
    private func write(_ image: NSImage, to url: URL) -> Bool {
        guard var cgImage = image.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ) else { return false }

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
