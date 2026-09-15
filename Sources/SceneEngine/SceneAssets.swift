import Diagnostics
import Foundation
import Metal
import WEFormat
import os

/// Resolves a wallpaper's assets, whether packed in a `scene.pkg` or sitting loose on disk.
///
/// Both layouts occur in the wild: Workshop items ship packed, but content authored locally in
/// the Wallpaper Engine editor is loose, and some items ship a `.pkg` alongside loose overrides
/// that take precedence. Callers should not have to care which they are looking at.
public final class SceneAssets {
    private let archive: PKGArchive?
    private let directory: URL
    private let loader = TextureLoader()
    private let log = Logger(subsystem: "app.diorama", category: "assets")

    /// Cached by resolved path. Two layers sharing a texture — extremely common, since scenes
    /// reuse a sprite across many objects — upload it once.
    private var textureCache: [String: any MTLTexture] = [:]

    public private(set) var report: CompatibilityReport

    public init(wallpaperID: String, directory: URL, packageURL: URL?) {
        self.directory = directory
        self.report = CompatibilityReport(wallpaperID: wallpaperID)

        if let packageURL, FileManager.default.fileExists(atPath: packageURL.path) {
            archive = try? PKGArchive(contentsOf: packageURL)
            if archive == nil {
                report.add(.unsupported, feature: "Package", detail: "scene.pkg could not be read")
            }
        } else {
            archive = nil
        }
    }

    /// Loose files win over packed ones, matching how the editor overrides package content.
    public func data(for path: String) -> Data? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")

        let looseURL = directory.appendingPathComponent(normalized)
        if let data = try? Data(contentsOf: looseURL) { return data }

        if let archive {
            if let data = try? archive.data(for: normalized) { return data }
            // Materials reference textures without an extension about as often as with one.
            for candidate in Self.pathVariants(normalized) {
                if let data = try? archive.data(for: candidate) { return data }
            }
        }

        for candidate in Self.pathVariants(normalized) {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(candidate)) {
                return data
            }
        }
        return nil
    }

    static func pathVariants(_ path: String) -> [String] {
        var variants: [String] = []
        let hasExtension = (path as NSString).pathExtension.isEmpty == false
        if !hasExtension {
            variants.append(path + ".tex")
            variants.append(path + ".json")
        } else {
            let stripped = (path as NSString).deletingPathExtension
            variants.append(stripped + ".tex")
        }
        // Textures are addressed both bare and under `materials/` depending on the authoring tool.
        if !path.hasPrefix("materials/") {
            variants.append("materials/" + path)
            if !hasExtension { variants.append("materials/" + path + ".tex") }
        }
        return variants
    }

    public func material(at path: String) -> MaterialDocument? {
        guard let data = data(for: path) ?? data(for: path + ".json") else {
            report.add(.degraded, feature: "Material", detail: "\(path) is missing")
            return nil
        }
        do {
            return try JSONDecoder().decode(MaterialDocument.self, from: data)
        } catch {
            report.add(.degraded, feature: "Material", detail: "\(path) could not be parsed")
            return nil
        }
    }

    public func texture(at path: String, device: any MTLDevice) -> (any MTLTexture)? {
        if let cached = textureCache[path] { return cached }

        guard let data = data(for: path) else {
            report.add(.degraded, feature: "Texture", detail: "\(path) is missing")
            return nil
        }

        do {
            let parsed = try TEXTexture(data: data)
            let texture = try loader.makeTexture(from: parsed, device: device, label: path)
            textureCache[path] = texture
            return texture
        } catch {
            report.add(
                .degraded, feature: "Texture",
                detail: "\(path): \(error.localizedDescription)"
            )
            return nil
        }
    }

    public var cachedTextureCount: Int { textureCache.count }

    public func purge() { textureCache.removeAll() }
}
