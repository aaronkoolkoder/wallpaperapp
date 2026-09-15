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
    /// Parallax response.
    public var parallaxDepth: SIMD2<Float>
    /// Post-process chain applied to this layer alone, before it is composited.
    public var effects: [PostEffect] = []
    public var isVisible: Bool

    /// Model matrix with a camera offset folded into the translation.
    public func modelMatrix(cameraOffset: SIMD2<Float>) -> simd_float4x4 {
        var matrix = modelMatrix
        let shift = cameraOffset * parallaxDepth
        matrix.columns.3.x += shift.x
        matrix.columns.3.y += shift.y
        return matrix
    }

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
    /// Parallax configuration as the scene declared it.
    public var cameraMotion: CameraMotion
    /// Live particle emitters, simulated each frame.
    public var particles: [ParticleSystem] = []
    /// Post-process chain applied to the fully composited frame.
    public var sceneEffects: [PostEffect] = []
    /// Compiled SceneScript bindings, evaluated once per frame.
    public var scriptBindings: [ScriptBinding] = []
    /// Owns the JavaScript context. Nil when no object in the scene is scripted, which is the
    /// overwhelming majority — no interpreter is created for a scene that does not need one.
    public var scriptRuntime: ScriptRuntime?
    public var report: CompatibilityReport

    /// Largest distance any layer can be displaced by parallax, in scene units.
    ///
    /// Used to zoom the projection just enough that deflection never uncovers the frame edge.
    public var maximumParallaxShift: SIMD2<Float> {
        guard cameraMotion.isEnabled else { return .zero }
        let travel = abs(cameraMotion.amount * cameraMotion.mouseInfluence)
        guard travel > 0 else { return .zero }

        var worst = SIMD2<Float>.zero
        for layer in layers where layer.isVisible {
            worst = simd_max(worst, abs(layer.parallaxDepth) * travel)
        }
        return worst
    }

    public var projectionMatrix: simd_float4x4 {
        // Maps the scene's ortho box onto clip space with Y up. Wallpaper Engine places the
        // origin at the centre of the scene, not a corner, so this is symmetric about zero.
        //
        // The box is widened by the worst-case parallax deflection. Wallpaper Engine leaves this
        // to the scene author — backgrounds are normally drawn oversized — but a scene authored
        // without that margin shows black at the edge the moment the camera moves, which reads
        // as a rendering bug rather than as content being tight. Widening the box zooms in just
        // enough to keep the frame covered, and costs nothing when parallax is off or depths
        // are zero.
        let margin = maximumParallaxShift
        let halfWidth = max(1, orthoSize.x) * 0.5 - margin.x
        let halfHeight = max(1, orthoSize.y) * 0.5 - margin.y
        return simd_float4x4(
            SIMD4(1 / max(1, halfWidth), 0, 0, 0),
            SIMD4(0, 1 / max(1, halfHeight), 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)
        )
    }
}

/// Binds one compiled script to the layer property it animates.
public struct ScriptBinding: Sendable, Hashable {
    public let layerIndex: Int
    /// `alpha`, `origin`, `angles`, `scale`, `color`, or `size`.
    public let property: String
    /// Opaque handle into the script runtime.
    public let handle: String

    public init(layerIndex: Int, property: String, handle: String) {
        self.layerIndex = layerIndex
        self.property = property
        self.handle = handle
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

    /// Map an effect definition onto a built-in implementation.
    ///
    /// Running a Wallpaper Engine effect faithfully means transpiling its GLSL to MSL, which is
    /// built but not yet wired to a native backend. Matching by name covers the effects that
    /// actually appear in most wallpapers, and anything unmatched is reported by name so the
    /// user learns what is missing instead of wondering why a scene looks flat.
    static func postEffect(for document: EffectDocument) -> PostEffect? {
        switch document.classifiedKind {
        case "bloom": .bloom(threshold: 0.6, intensity: 0.8)
        case "blur": .gaussianBlur(radius: 4)
        case "vignette": .vignette(intensity: 0.6)
        case "chromatic": .chromaticAberration(amount: 1.0)
        case "sharpen": .sharpen(amount: 0.4)
        case "pixelate": .pixelate(size: 6)
        default: nil
        }
    }

    private func resolveEffects(
        _ effects: [SceneEffect],
        assets: SceneAssets,
        owner: String,
        report: inout CompatibilityReport
    ) -> [PostEffect] {
        var resolved: [PostEffect] = []
        for effect in effects {
            if let visible = effect.visible?.staticValue, !visible { continue }
            guard let path = effect.file else { continue }
            guard let data = assets.data(for: path) ?? assets.data(for: path + ".json"),
                  let document = try? JSONDecoder().decode(EffectDocument.self, from: data)
            else {
                report.add(.degraded, feature: "Effect", detail: "\(path) could not be read")
                continue
            }
            if let post = Self.postEffect(for: document) {
                resolved.append(post)
            } else {
                report.add(
                    .degraded, feature: "Effect",
                    detail: "\(document.name ?? path) is not supported yet"
                )
            }
        }
        return resolved
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
        var systems: [ParticleSystem] = []
        var bindings: [ScriptBinding] = []
        var scriptRuntime: ScriptRuntime?

        let ortho = document.general?.orthogonalProjection
        let orthoSize = SIMD2<Float>(
            Float(ortho?.width ?? 1920), Float(ortho?.height ?? 1080)
        )

        for object in document.objects {
            switch object.kind {
            case .image:
                if var layer = buildImageLayer(object, assets: assets, device: device, report: &report) {
                    layer.effects = resolveEffects(
                        object.effects, assets: assets,
                        owner: layer.name, report: &report
                    )
                    let layerIndex = layers.count
                    layers.append(layer)

                    for (property, body) in object.scripts.sorted(by: { $0.key < $1.key }) {
                        // Create the interpreter lazily: a scene with no scripts never pays for
                        // a JSContext at all.
                        if scriptRuntime == nil { scriptRuntime = ScriptRuntime() }
                        guard let runtime = scriptRuntime else {
                            report.add(
                                .degraded, feature: "Script",
                                detail: "could not start the script interpreter"
                            )
                            break
                        }
                        if let handle = runtime.compile(body, name: "\(layer.name).\(property)") {
                            bindings.append(
                                ScriptBinding(
                                    layerIndex: layerIndex, property: property, handle: handle
                                )
                            )
                        }
                    }
                }
            case .particle:
                if let system = buildParticleSystem(
                    object, assets: assets, device: device, report: &report
                ) {
                    systems.append(system)
                }
            case .text:
                if let layer = buildTextLayer(object, device: device, report: &report) {
                    layers.append(layer)
                }
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

        // Scene-wide bloom is declared on `general` rather than as an effect file, and is by
        // far the most common post-process in Workshop content.
        var sceneEffects: [PostEffect] = []
        if document.general?.bloom == true {
            sceneEffects.append(
                .bloom(
                    threshold: Float(document.general?.bloomThreshold ?? 0.6),
                    intensity: Float(document.general?.bloomStrength ?? 0.8)
                )
            )
        }

        // Merge in everything the asset resolver recorded while we were loading.
        for finding in assets.report.findings { report.add(finding) }
        for finding in scriptRuntime?.findings ?? [] { report.add(finding) }

        let clear = document.general?.clearColor
        return RenderableScene(
            layers: layers,
            orthoSize: orthoSize,
            clearColor: SIMD4(
                Float(clear?.x ?? 0), Float(clear?.y ?? 0), Float(clear?.z ?? 0), 1
            ),
            cameraMotion: CameraMotion(general: document.general),
            particles: systems,
            sceneEffects: sceneEffects,
            scriptBindings: bindings,
            scriptRuntime: scriptRuntime,
            report: report
        )
    }

    private func buildParticleSystem(
        _ object: SceneObject,
        assets: SceneAssets,
        device: any MTLDevice,
        report: inout CompatibilityReport
    ) -> ParticleSystem? {
        guard let path = object.particle else { return nil }
        guard let data = assets.data(for: path) ?? assets.data(for: path + ".json") else {
            report.add(.degraded, feature: "Particle system", detail: "\(path) is missing")
            return nil
        }

        let document: ParticleDocument
        do {
            document = try JSONDecoder().decode(ParticleDocument.self, from: data)
        } catch {
            report.add(.degraded, feature: "Particle system", detail: "\(path) could not be parsed")
            return nil
        }

        let system = ParticleSystem(document: document)
        let origin = object.origin ?? WEVector3(0, 0, 0)
        system.origin = SIMD3(Float(origin.x), Float(origin.y), Float(origin.z))

        // Particles are almost always additive; that is what makes snow, embers and dust read
        // as light rather than as opaque sprites.
        if let materialPath = system.materialPath,
           let material = assets.material(at: materialPath),
           let pass = material.firstPass {
            system.blend = Self.blendMode(named: pass.blending)
            if let texturePath = pass.primaryTexture {
                system.texture = assets.texture(at: texturePath, device: device)
            }
        }

        // Surface whatever behaviours the emitter needed and we do not implement.
        for finding in system.findings { report.add(finding) }
        return system
    }

    private func buildTextLayer(
        _ object: SceneObject,
        device: any MTLDevice,
        report: inout CompatibilityReport
    ) -> RenderableLayer? {
        var findings: [CompatibilityFinding] = []
        guard let rendered = TextLayerRenderer().makeTexture(
            for: object, device: device, findings: &findings
        ) else {
            report.add(
                .degraded, feature: "Text layer",
                detail: object.name.map { "\"\($0)\" could not be rendered" }
            )
            return nil
        }
        for finding in findings { report.add(finding) }

        let origin = object.origin ?? WEVector3(0, 0, 0)
        let angles = object.angles ?? WEVector3(0, 0, 0)
        let scale = object.scale ?? WEVector3(1, 1, 1)
        let parallax = object.parallaxDepth

        // Size comes from the rasterised bitmap, not from the object's declared size: the text
        // has a real aspect ratio and forcing it into a declared box would stretch the glyphs.
        return RenderableLayer(
            name: object.name ?? "Text",
            origin: SIMD3(Float(origin.x), Float(origin.y), Float(origin.z)),
            angles: SIMD3(
                Float(angles.x) * .pi / 180,
                Float(angles.y) * .pi / 180,
                Float(angles.z) * .pi / 180
            ),
            scale: SIMD3(Float(scale.x), Float(scale.y), Float(scale.z)),
            size: rendered.size,
            // Colour is already baked into the glyphs, so the tint carries opacity only.
            tint: SIMD4(1, 1, 1, Float(object.alpha ?? 1)),
            blend: .premultipliedAlpha,
            texture: rendered.texture,
            parallaxDepth: SIMD2(Float(parallax?.x ?? 0), Float(parallax?.y ?? 0)),
            isVisible: object.visible?.staticValue ?? true
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
