import Foundation
import WEFormat
import os

/// Indexes a Wallpaper Engine content directory.
///
/// Expects the layout Steam produces — `.../steamapps/workshop/content/431960/<id>/project.json`
/// — but does not require it: any directory containing numbered subdirectories with a
/// `project.json` will scan, since users copy this folder around by hand (PLAN.md §2.1) and it
/// arrives nested differently depending on how they moved it.
public struct LibraryScanner: Sendable {
    /// Wallpaper Engine's Steam application ID. Used only to recognise the folder, never to talk
    /// to Steam.
    public static let wallpaperEngineAppID = "431960"

    private let log = Logger(subsystem: "app.diorama", category: "scan")

    public init() {}

    /// Locate the item root inside whatever the user picked.
    ///
    /// Accepts being handed `content`, `431960`, or a folder that merely contains one — people
    /// drag in whichever level they happened to copy, and rejecting all but the exact directory
    /// is a needless failure.
    public func resolveRoot(from url: URL) -> URL {
        let fm = FileManager.default
        let appIDChild = url.appendingPathComponent(Self.wallpaperEngineAppID)
        if fm.fileExists(atPath: appIDChild.path) { return appIDChild }

        let nested = url
            .appendingPathComponent("steamapps/workshop/content")
            .appendingPathComponent(Self.wallpaperEngineAppID)
        if fm.fileExists(atPath: nested.path) { return nested }

        return url
    }

    public func scan(root: URL) -> ScanResult {
        let started = Date()
        let fm = FileManager.default
        var result = ScanResult()

        let root = resolveRoot(from: root)
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            log.error("could not read \(root.path, privacy: .public)")
            return result
        }

        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            result.scannedDirectories += 1

            let manifestURL = child.appendingPathComponent("project.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            do {
                result.items.append(try indexItem(directory: child, manifestURL: manifestURL))
            } catch {
                // One malformed wallpaper must never abort a 300-item scan.
                result.failures.append((child.lastPathComponent, error.localizedDescription))
                log.warning("skipped \(child.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        result.items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        result.duration = Date().timeIntervalSince(started)
        log.info("indexed \(result.items.count) item(s) in \(String(format: "%.2f", result.duration))s")
        return result
    }

    private func indexItem(directory: URL, manifestURL: URL) throws -> WallpaperItem {
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: data)
        let fm = FileManager.default

        let contentURL = manifest.file
            .map { directory.appendingPathComponent($0) }
            .flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }

        let previewURL = manifest.preview
            .map { directory.appendingPathComponent($0) }
            .flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Self.findPreview(in: directory)

        let attributes = try? fm.attributesOfItem(atPath: manifestURL.path)

        return WallpaperItem(
            id: directory.lastPathComponent,
            title: manifest.title.isEmpty ? directory.lastPathComponent : manifest.title,
            type: manifest.type,
            directory: directory,
            contentURL: contentURL,
            previewURL: previewURL,
            tags: manifest.tags,
            contentRating: manifest.contentRating,
            properties: manifest.general?.properties ?? [:],
            sizeBytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: attributes?[.modificationDate] as? Date,
            unplayableReason: Self.unplayableReason(for: manifest, contentURL: contentURL)
        )
    }

    /// Stated in the user's terms, not the format's. "Windows-only" is actionable; a raw enum
    /// case is not.
    private static func unplayableReason(
        for manifest: ProjectManifest, contentURL: URL?
    ) -> String? {
        switch manifest.type {
        case .application:
            return "Application wallpapers are Windows programs and cannot run on macOS"
        case .unknown(let raw):
            return raw.isEmpty
                ? "This wallpaper does not say what type it is"
                : "Unrecognised wallpaper type \"\(raw)\""
        case .scene, .video, .web:
            if contentURL == nil {
                return manifest.file.map { "The file \($0) is missing from this wallpaper" }
                    ?? "This wallpaper does not name a content file"
            }
            return nil
        }
    }

    private static func findPreview(in directory: URL) -> URL? {
        let fm = FileManager.default
        for name in ["preview.jpg", "preview.png", "preview.gif", "preview.jpeg"] {
            let candidate = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
