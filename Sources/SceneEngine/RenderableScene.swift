import Diagnostics
import Foundation
import Metal
import MetalRenderer
import ShaderTranspiler
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
    public var effects: [LayerEffect] = []
    public var isVisible: Bool

    /// The material's own compiled shader, when it could be built.
    ///
    /// Nil means this layer draws through the built-in quad shader instead — either because the
    /// shader toolchain is not vendored in this build, or because the material's shader could
    /// not be compiled. Both cases are reported; neither drops the layer.
    public var program: MaterialProgram?

    /// Textures for the material's samplers, keyed by GLSL name (`g_Texture0` and friends).
    public var materialTextures: [String: any MTLTexture] = [:]

    /// Uniform values baked into the material by the wallpaper's author.
    public var materialConstants: [String: DynamicValue] = [:]

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
    public var sceneEffects: [LayerEffect] = []
    /// Compiled SceneScript bindings, evaluated once per frame.
    public var scriptBindings: [ScriptBinding] = []
    /// Owns the JavaScript context. Nil when no object in the scene is scripted, which is the
    /// overwhelming majority — no interpreter is created for a scene that does not need one.
    public var scriptRuntime: ScriptRuntime?
    public var report: CompatibilityReport

    /// Layers drawing through their material's own compiled shader.
    ///
    /// Reported alongside the layer count because "renders cleanly" does not distinguish a
    /// wallpaper running the author's shaders from one approximating them, and that is the
    /// distinction the transpilation work exists to move.
    public var layersWithOwnShaders: Int { layers.filter { $0.program != nil }.count }

    /// Effects running the author's own passes, across the scene and every layer.
    public var compiledEffectCount: Int {
        (sceneEffects + layers.flatMap(\.effects)).filter(\.isCompiled).count
    }

    /// Effects standing in as a built-in approximation of the author's.
    public var approximatedEffectCount: Int {
        (sceneEffects + layers.flatMap(\.effects)).filter { !$0.isCompiled }.count
    }

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
    /// Only reached when the effect's own shaders could not be compiled — see `resolveEffects`,
    /// which tries the author's passes first. Matching by name covers the effects that actually
    /// appear in most wallpapers, and anything unmatched is reported by name so the user learns
    /// what is missing instead of wondering why a scene looks flat.
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
        device: any MTLDevice,
        materials: MaterialCompiler?,
        owner: String,
        report: inout CompatibilityReport
    ) -> [LayerEffect] {
        var resolved: [LayerEffect] = []
        for effect in effects {
            if let visible = effect.visible?.staticValue, !visible { continue }
            guard let path = effect.file else { continue }
            guard let data = assets.data(for: path) ?? assets.data(for: path + ".json"),
                  let document = try? JSONDecoder().decode(EffectDocument.self, from: data)
            else {
                report.add(.degraded, feature: "Effect", detail: "\(path) could not be read")
                continue
            }

            // The author's own passes first. Matching by name is the fallback it used to be,
            // not the plan: it covers six common effects and flattens the rest.
            if let materials,
               let compiled = materials.effect(
                   for: document, assets: assets, device: device, report: &report
               ) {
                resolved.append(.compiled(compiled))
                continue
            }

            if let post = Self.postEffect(for: document) {
                resolved.append(.builtIn(post))
                report.add(
                    .degraded, feature: "Effect",
                    detail: "\(document.name ?? path) is approximated rather than run as written"
                )
            } else {
                report.add(
                    .degraded, feature: "Effect",
                    detail: "\(document.name ?? path) is not supported yet"
                )
            }
        }
        return resolved
    }

    /// - Parameter materials: compiles each material's own shader when supplied. Without one,
    ///   every layer draws through the built-in quad shader, which is what the app did before
    ///   the transpiler existed and remains the fallback when a shader will not compile.
    public func build(
        document: SceneDocument,
        assets: SceneAssets,
        device: any MTLDevice,
        materials: MaterialCompiler? = nil
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
                if var layer = buildImageLayer(
                    object, assets: assets, device: device, materials: materials, report: &report
                ) {
                    layer.effects = resolveEffects(
                        object.effects, assets: assets, device: device, materials: materials,
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
        var sceneEffects: [LayerEffect] = []
        if document.general?.bloom == true {
            // Declared on `general` rather than as an effect file, so there is no author
            // shader to compile — the built-in one is the faithful answer here, not a fallback.
            sceneEffects.append(
                .builtIn(
                    .bloom(
                        threshold: Float(document.general?.bloomThreshold ?? 0.6),
                        intensity: Float(document.general?.bloomStrength ?? 0.8)
                    )
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
        materials: MaterialCompiler?,
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

        let compiled = compileMaterial(
            pass, name: imagePath, assets: assets, device: device,
            primaryTexture: texture, materials: materials, report: &report
        )

        var layer = RenderableLayer(
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
        layer.program = compiled?.program
        layer.materialTextures = compiled?.textures ?? [:]
        layer.materialConstants = pass.constantShaderValues
        return layer
    }

    /// Which sampler a material's texture slot feeds.
    ///
    /// The name `g_TextureN` wins when the shader declares it, because that is the convention
    /// the material's array is written against. Declaration order is the fallback for shaders
    /// that name their samplers something else entirely, and it only considers samplers that are
    /// not themselves `g_Texture*` — otherwise a shader declaring `g_Texture1` but not
    /// `g_Texture0` would have slot 0 fall through onto `g_Texture1`.
    static func samplerName(forTextureSlot slot: Int, declared: [String]) -> String {
        let conventional = "g_Texture\(slot)"
        if declared.contains(conventional) { return conventional }

        let unconventional = declared.filter { !$0.hasPrefix("g_Texture") }
        if slot < unconventional.count { return unconventional[slot] }
        return conventional
    }

    /// A shader finding as one line, without repeating what the report already shows.
    ///
    /// `ShaderDiagnostic.description` leads with the severity and trails with the kind, both of
    /// which the surrounding report carries already.
    static func summary(of diagnostic: ShaderDiagnostic) -> String {
        let location = diagnostic.line.map { line in
            "\(diagnostic.originFile ?? diagnostic.shaderName):\(line): "
        } ?? ""
        return ShaderMessageText.oneLine(location + diagnostic.message)
    }

    /// Compiles a pass's shader and resolves the textures it samples.
    ///
    /// Returns nil — and reports why — whenever the layer should fall back to the built-in quad
    /// shader. Falling back rather than dropping the layer matters: a wallpaper missing one
    /// effect is still recognisably itself, while a wallpaper missing a layer is not.
    private func compileMaterial(
        _ pass: MaterialPass,
        name: String,
        assets: SceneAssets,
        device: any MTLDevice,
        primaryTexture: (any MTLTexture)?,
        materials: MaterialCompiler?,
        report: inout CompatibilityReport
    ) -> (program: MaterialProgram, textures: [String: any MTLTexture])? {
        guard let materials, materials.isAvailable else { return nil }
        guard let shader = pass.shader, !shader.isEmpty else { return nil }

        let program: MaterialProgram
        do {
            program = try materials.program(for: pass, assets: assets)
        } catch {
            // The preprocessor's own findings first: they usually name the line the author
            // wrote, where the backend names a rule the author never wrote against.
            if let failure = error as? MaterialProgramError {
                for diagnostic in failure.diagnostics where diagnostic.severity != .info {
                    report.add(
                        .degraded, feature: "Shader",
                        detail: "\(shader): \(Self.summary(of: diagnostic))"
                    )
                }
            }
            report.add(
                .degraded, feature: "Shader",
                detail: "\(shader): \(ShaderMessageText.oneLine(error.localizedDescription)) — drawn without it"
            )
            return nil
        }

        for diagnostic in program.diagnostics where diagnostic.severity != .info {
            // Always degraded at the wallpaper level, whatever the shader-level severity. A
            // shader that will not compile is unsupported *as a shader*, but the layer still
            // draws through the built-in one with its own textures — the wallpaper looks like
            // itself, flatter. Reserving `unsupported` for "nothing renders" is what keeps that
            // word meaning something in the report.
            report.add(
                .degraded, feature: "Shader",
                detail: "\(shader): \(Self.summary(of: diagnostic))"
            )
        }

        // A material's `textures` array is positional, and Wallpaper Engine's convention is that
        // entry n is the sampler *named* `g_TextureN` — not the nth sampler the shader happens
        // to declare. The two differ whenever a shader declares another sampler first, which is
        // routine: a `#if`-guarded mask declared above `g_Texture0` would otherwise take slot 0
        // and the colour map would be bound to a sampler the shader does not read, leaving the
        // layer flat white.
        var textures: [String: any MTLTexture] = [:]
        for (index, path) in pass.textures.enumerated() {
            let samplerName = Self.samplerName(
                forTextureSlot: index, declared: program.declaredSamplers
            )
            if index == 0, let primaryTexture {
                textures[samplerName] = primaryTexture
                continue
            }
            guard let path, !path.isEmpty else { continue }
            if let texture = assets.texture(at: path, device: device) {
                textures[samplerName] = texture
            }
        }
        if textures.isEmpty, let primaryTexture, let first = program.declaredSamplers.first {
            textures[first] = primaryTexture
        }

        return (program, textures)
    }
}
