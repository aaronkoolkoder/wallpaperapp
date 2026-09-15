import Diagnostics
import Foundation
import Metal
import MetalRenderer
import WEFormat
import simd
import os

/// One draw-ready layer, flattened from a `SceneObject`.
public struct RenderableLayer: @unchecked Sendable {
    public var name: String
    /// Scene-space placement, in the scene's own orthographic units.
    public var origin: SIMD3<Float>
    /// Euler angles in radians. Only Z matters for a 2D scene, but all three are carried so a
    /// later 3D pass does not have to re-derive them.
    public var angles: SIMD3<Float>
    public var scale: SIMD3<Float>
    /// Quad size in scene units, from the material's texture dimensions unless overridden.
    public var size: SIMD2<Float>
    public var tint: SIMD4<Float>
    public var blend: BlendMode
    public var texture: (any MTLTexture)?
    /// Parallax response, unused until camera motion lands in M5.
    public var parallaxDepth: SIMD2<Float>
    public var isVisible: Bool

    /// Model matrix. Order is scale, then rotate, then translate — reversing rotation and
    /// translation would orbit each layer around the scene origin instead of spinning in place.
    public var modelMatrix: simd_float4x4 {
        let s = simd_float4x4(diagonal: SIMD4(size.x * scale.x, size.y * scale.y, 1, 1))
        let c = cosf(angles.z), sn = sinf(angles.z)
        let r = simd_float4x4(
            SIMD4( c, sn, 0, 0),
            SIMD4(-sn, c, 0, 0),
            SIMD4( 0,  0, 1, 0),
            SIMD4( 0,  0, 0, 1)
        )
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4(origin.x, origin.y, origin.z, 1)
        return t * r * s
    }
}

/// A scene flattened into layers, ready to draw.
public struct RenderableScene: @unchecked Sendable {
    public var layers: [RenderableLayer]
    /// Orthographic extent in scene units. Draw coordinates are expressed in this space.
    public var orthoSize: SIMD2<Float>
    public var clearColor: SIMD4<Float>
    public var report: CompatibilityReport

    public var projectionMatrix: simd_float4x4 {
        // Maps the scene's ortho box onto clip space with Y up. Wallpaper Engine places the
        // origin at the centre of the scene, not a corner, so this is symmetric about zero.
        let halfWidth = max(1, orthoSize.x) * 0.5
        let halfHeight = max(1, orthoSize.y) * 0.5
        return simd_float4x4(
            SIMD4(1 / halfWidth, 0, 0, 0),
            SIMD4(0, 1 / halfHeight, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)
        )
    }
}

/// Builds a ``RenderableScene`` from a parsed scene document.
public struct SceneBuilder {
    private let log = Logger(subsystem: "app.diorama", category: "scene")

    public init() {}

    /// Wallpaper Engine names blend modes as strings in material passes.
    static func blendMode(named name: String?) -> BlendMode {
        switch name?.lowercased() {
        case "additive": .premultipliedAdditive
        case "multiply": .premultipliedMultiply
        case "screen": .premultipliedScreen
        case "normal", "translucent", .none: .premultipliedAlpha
        default: .premultipliedAlpha
        }
    }

    public func build(
        document: SceneDocument,
        assets: SceneAssets,
        device: any MTLDevice
    ) -> RenderableScene {
        // Findings raised *during* this build only. The asset resolver's own findings are
        // merged at the end, not snapshotted here: CompatibilityReport is a value type, so
        // copying it up front would silently discard every missing-texture and missing-material
        // finding raised by the lookups below. Caught by a test.
        var report = CompatibilityReport(wallpaperID: assets.report.wallpaperID)
        var layers: [RenderableLayer] = []

        let ortho = document.general?.orthogonalProjection
        let orthoSize = SIMD2<Float>(
            Float(ortho?.width ?? 1920), Float(ortho?.height ?? 1080)
        )

        for object in document.objects {
            switch object.kind {
            case .image:
                if let layer = buildImageLayer(object, assets: assets, device: device, report: &report) {
                    layers.append(layer)
                }
            case .particle:
                report.add(
                    .degraded, feature: "Particle systems",
                    detail: object.name.map { "\"\($0)\" is not drawn yet" }
                )
            case .text:
                report.add(
                    .degraded, feature: "Text layers",
                    detail: object.name.map { "\"\($0)\" is not drawn yet" }
                )
            case .sound:
                // Silent by design; not a defect worth reporting.
                break
            case .unknown:
                report.add(
                    .degraded, feature: "Unknown object type",
                    detail: object.name.map { "\"\($0)\" uses an object type we do not recognise" }
                )
            }
        }

        // Effects, SceneScript and camera motion are M5/M6. Say so once for the whole scene
        // rather than once per object, which would bury the report in noise.
        if document.objects.contains(where: { !$0.effects.isEmpty }) {
            report.add(
                .degraded, feature: "Effects",
                detail: "post-processing effect chains are not applied yet"
            )
        }

        // Merge in everything the asset resolver recorded while we were loading.
        for finding in assets.report.findings { report.add(finding) }

        let clear = document.general?.clearColor
        return RenderableScene(
            layers: layers,
            orthoSize: orthoSize,
            clearColor: SIMD4(
                Float(clear?.x ?? 0), Float(clear?.y ?? 0), Float(clear?.z ?? 0), 1
            ),
            report: report
        )
    }

    private func buildImageLayer(
        _ object: SceneObject,
        assets: SceneAssets,
        device: any MTLDevice,
        report: inout CompatibilityReport
    ) -> RenderableLayer? {
        guard let imagePath = object.image else { return nil }
        guard let material = assets.material(at: imagePath) else { return nil }
        guard let pass = material.firstPass else {
            report.add(.degraded, feature: "Material", detail: "\(imagePath) declares no passes")
            return nil
        }

        var texture: (any MTLTexture)?
        if let texturePath = pass.primaryTexture {
            texture = assets.texture(at: texturePath, device: device)
        }

        // Fall back to the texture's own dimensions when the object does not state a size, which
        // is the common case for a layer that is simply its image at natural scale.
        let size: SIMD2<Float>
        if let declared = object.size {
            size = SIMD2(Float(declared.x), Float(declared.y))
        } else if let texture {
            size = SIMD2(Float(texture.width), Float(texture.height))
        } else {
            size = SIMD2(100, 100)
        }

        let origin = object.origin ?? WEVector3(0, 0, 0)
        let angles = object.angles ?? WEVector3(0, 0, 0)
        let scale = object.scale ?? WEVector3(1, 1, 1)
        let colour = object.color ?? WEVector3(1, 1, 1)
        let parallax = object.parallaxDepth

        return RenderableLayer(
            name: object.name ?? imagePath,
            origin: SIMD3(Float(origin.x), Float(origin.y), Float(origin.z)),
            angles: SIMD3(
                Float(angles.x) * .pi / 180,
                Float(angles.y) * .pi / 180,
                Float(angles.z) * .pi / 180
            ),
            scale: SIMD3(Float(scale.x), Float(scale.y), Float(scale.z)),
            size: size,
            tint: SIMD4(
                Float(colour.x), Float(colour.y), Float(colour.z), Float(object.alpha ?? 1)
            ),
            blend: Self.blendMode(named: pass.blending),
            texture: texture,
            parallaxDepth: SIMD2(
                Float(parallax?.x ?? 0), Float(parallax?.y ?? 0)
            ),
            isVisible: object.visible?.staticValue ?? true
        )
    }
}
