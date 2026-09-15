import AVFoundation
import AppKit
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
        let destination = cacheDirectory.appendingPathComponent("\(wallpaperID).png")

        // Stills are deterministic for a given wallpaper, so a cache hit skips video decoding
        // entirely on every subsequent switch.
        if fileManager.fileExists(atPath: destination.path) { return destination }

        let image: NSImage?
        switch contentURL.pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "webm", "mkv", "avi":
            image = videoFrame(from: contentURL)
        default:
            image = NSImage(contentsOf: contentURL)
        }

        guard let image, let png = pngData(from: image) else { return nil }
        do {
            try png.write(to: destination, options: .atomic)
            return destination
        } catch {
            log.error("could not write still: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Pull a frame from a little way in. The first frame of a video wallpaper is often a fade
    /// from black, which would tint the menu bar for a colour the user never actually sees.
    private func videoFrame(from url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let time = CMTime(seconds: 2, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            // Retry at zero for videos shorter than the offset.
            guard let first = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                return nil
            }
            return NSImage(cgImage: first, size: .zero)
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
