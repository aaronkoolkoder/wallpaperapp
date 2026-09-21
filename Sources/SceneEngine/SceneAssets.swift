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
    private var textureCache: [String: SceneTexture] = [:]

    public private(set) var report: CompatibilityReport

    public init(wallpaperID: String, directory: URL, packageURL: URL?) {
        self.directory = directory
        self.report = CompatibilityReport(wallpaperID: wallpaperID)

        // Only a `.pkg` is a package. A wallpaper authored in the editor ships its scene loose
        // and names `scene.json` as its content file, and callers pass that same URL through —
        // reading it as an archive fails and used to report every such wallpaper as having an
        // unreadable package, which is both wrong and alarming.
        if let packageURL, packageURL.pathExtension.lowercased() == "pkg",
           FileManager.default.fileExists(atPath: packageURL.path) {
            archive = try? PKGArchive(contentsOf: packageURL)
            if archive == nil {
                report.add(
                    .unsupported, feature: "Package",
                    detail: "\(packageURL.lastPathComponent) could not be read"
                )
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

    /// The material a scene object's `image` path leads to.
    ///
    /// Workshop scenes point `image` at a *model* (`models/foo.json`), which names the material
    /// (`materials/foo.json`). Locally authored content sometimes points straight at a material,
    /// so both are accepted: whatever is there is read as a material first, and only if it
    /// declares no passes is it re-read as a model and followed.
    public func resolvedMaterial(forImage path: String) -> (material: MaterialDocument, model: ModelDocument?)? {
        guard let data = data(for: path) ?? data(for: path + ".json") else {
            report.add(.degraded, feature: "Material", detail: "\(path) is missing")
            return nil
        }

        if let direct = try? JSONDecoder().decode(MaterialDocument.self, from: data),
           !direct.passes.isEmpty {
            return (direct, nil)
        }

        guard let model = try? JSONDecoder().decode(ModelDocument.self, from: data) else {
            report.add(.degraded, feature: "Material", detail: "\(path) could not be parsed")
            return nil
        }
        guard let materialPath = model.material else {
            report.add(.degraded, feature: "Model", detail: "\(path) names no material")
            return nil
        }
        guard let material = material(at: materialPath) else { return nil }

        if let puppet = model.puppet {
            report.add(
                .degraded, feature: "Puppet warp",
                detail: "\(puppet) drives bone animation, which is not supported — the layer is drawn undeformed"
            )
        }
        return (material, model)
    }

    /// The texture, and the size of the image inside it.
    ///
    /// Wallpaper Engine pads a `.tex` up to a power of two and records the real image size in
    /// the header, so a 2372x1334 painting arrives as a 4096x2048 allocation with the image in
    /// the top-left corner and nothing in the rest. Anything that maps a UV has to know both
    /// sizes; sampling 0..1 shows the empty margin as though it were content, which is what put
    /// a wallpaper in the corner of the desktop surrounded by the clear colour.
    public func sceneTexture(at path: String, device: any MTLDevice) -> SceneTexture? {
        if let cached = textureCache[path] { return cached }

        guard let data = data(for: path) else {
            report.add(.degraded, feature: "Texture", detail: "\(path) is missing")
            return nil
        }

        do {
            let parsed = try TEXTexture(data: data)
            let texture = try loader.makeTexture(from: parsed, device: device, label: path)
            // An encoded texture decodes to exactly the image, so the header's image size can
            // exceed what was allocated; clamp rather than describe a region that is not there.
            let loaded = SceneTexture(
                texture: texture,
                imageSize: SIMD2(
                    Float(min(max(parsed.imageWidth, 1), texture.width)),
                    Float(min(max(parsed.imageHeight, 1), texture.height))
                )
            )
            textureCache[path] = loaded
            return loaded
        } catch {
            report.add(
                .degraded, feature: "Texture",
                detail: "\(path): \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// For callers that only sample 0..1 anyway — particle sprites and effect bindings, whose
    /// UVs come from the emitter or the pass rather than from a layer's geometry.
    public func texture(at path: String, device: any MTLDevice) -> (any MTLTexture)? {
        sceneTexture(at: path, device: device)?.texture
    }

    public var cachedTextureCount: Int { textureCache.count }

    public func purge() { textureCache.removeAll() }
}
