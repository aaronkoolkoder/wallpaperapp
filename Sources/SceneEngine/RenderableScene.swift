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
    /// The UV the image ends at, which is 1 unless the texture was padded to a power of two.
    public var uvScale: SIMD2<Float> = SIMD2(1, 1)
    /// Frames of an animated texture. The renderer points `texture` and `spriteFrame` at the
    /// frame showing now.
    public var sprite: SpriteAnimation?
    public var spriteFrame: SpriteAnimation.Frame?

    /// The part of the texture this layer shows: the current animation frame, or the image
    /// inside a padded allocation.
    public var uvRect: SIMD4<Float> {
        if let spriteFrame { return spriteFrame.uvRect }
        return SIMD4(0, 0, uvScale.x, uvScale.y)
    }
    /// Parallax response.
    public var parallaxDepth: SIMD2<Float>
    /// Post-process chain applied to this layer alone, before it is composited.
    public var effects: [LayerEffect] = []
    public var isVisible: Bool
    /// Set when the object's visibility is tied to a user property; `isVisible` then only
    /// holds the value it was saved with. See `isShown(with:)`.
    public var visibilityBinding: SceneVisibility?

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

    /// `g_TextureNResolution` per sampler: allocation in `xy`, image in `zw`.
    public var materialTextureSizes: [String: SIMD4<Float>] = [:]

    /// Samplers whose texture was authored to tile.
    public var materialRepeatingTextures: Set<String> = []

    /// Whether the layer draws, given the user's current settings.
    ///
    /// A property-bound layer follows the property; anything else follows `isVisible`, which is
    /// also what scripts write to.
    public func isShown(with properties: [String: DynamicValue]) -> Bool {
        visibilityBinding?.isVisible(with: properties) ?? isVisible
    }

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
    /// Text layers whose string comes from a script — clocks and dates.
    public var textBindings: [TextBinding] = []
    /// Layer properties on an editor timeline.
    public var animationBindings: [AnimationBinding] = []
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
        // Including layers the user can switch on: sizing the margin only for what shows now
        // would make the whole scene zoom the moment one of them was turned on.
        for layer in layers where layer.isVisible || layer.visibilityBinding != nil {
            worst = simd_max(worst, abs(layer.parallaxDepth) * travel)
        }
        return worst
    }

    public var projectionMatrix: simd_float4x4 {
        // Maps the scene's ortho box onto clip space with Y up, with the origin at a *corner*.
        //
        // Not symmetric about zero, which is what it assumed until real content disproved it: a
        // full-screen layer in a 1920x1080 scene is placed at origin "960 540 0", the centre of
        // the box measured from its corner. Treating that as an offset from the middle pushed
        // every layer up and to the right by half a screen, so a wallpaper rendered with its
        // background in one quadrant.
        //
        // The box is widened by the worst-case parallax deflection. Wallpaper Engine leaves this
        // to the scene author — backgrounds are normally drawn oversized — but a scene authored
        // without that margin shows black at the edge the moment the camera moves, which reads
        // as a rendering bug rather than as content being tight. Widening the box zooms in just
        // enough to keep the frame covered, and costs nothing when parallax is off or depths
        // are zero.
        let margin = maximumParallaxShift
        let halfWidth = max(1, max(1, orthoSize.x) * 0.5 - margin.x)
        let halfHeight = max(1, max(1, orthoSize.y) * 0.5 - margin.y)
        let centre = SIMD2(max(1, orthoSize.x) * 0.5, max(1, orthoSize.y) * 0.5)

        // Scale about the box's centre and shift the corner origin onto it.
        let scaleX = 1 / halfWidth
        let scaleY = 1 / halfHeight
        return simd_float4x4(
            SIMD4(scaleX, 0, 0, 0),
            SIMD4(0, scaleY, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(-centre.x * scaleX, -centre.y * scaleY, 0, 1)
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

/// A layer property driven by a timeline animation.
///
/// Measured against real content: positions and angles animate as offsets from the value the
/// layer was saved with — a ship's keyframes run from +250 to -2645 around its origin — while
/// alpha, scale and colour animate as multipliers, which is how an intro logo saved at alpha 1
/// with keys of 1, 1 and 0 fades out.
public struct AnimationBinding: Sendable {
    public let layerIndex: Int
    public let property: String
    public let animation: PropertyAnimation
    /// The layer's own value for `property`, which the animation is relative to.
    public let base: SIMD4<Float>

    /// The property's value `seconds` in.
    public func apply(at seconds: Double, to layer: inout RenderableLayer) {
        let values = animation.values(at: seconds).map(Float.init)
        func channel(_ index: Int, _ fallback: Float) -> Float {
            index < values.count && values[index].isFinite ? values[index] : fallback
        }
        switch property {
        case "origin":
            layer.origin = SIMD3(base.x + channel(0, 0), base.y + channel(1, 0), base.z + channel(2, 0))
        case "angles":
            layer.angles = SIMD3(base.x + channel(0, 0), base.y + channel(1, 0), base.z + channel(2, 0))
        case "scale":
            layer.scale = SIMD3(base.x * channel(0, 1), base.y * channel(1, 1), base.z * channel(2, 1))
        case "alpha":
            layer.tint.w = base.w * channel(0, 1)
        case "color":
            layer.tint = SIMD4(
                base.x * channel(0, 1), base.y * channel(1, 1), base.z * channel(2, 1), layer.tint.w
            )
        default:
            break
        }
    }
}

/// A text layer whose string a script writes, and how to draw it when the string changes.
public struct TextBinding: @unchecked Sendable {
    public let layerIndex: Int
    /// Opaque handle into the script runtime.
    public let handle: String
    let style: TextLayerRenderer.Style
    /// What the layer showed when the scene was built.
    public let text: String
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

    /// The same names, for a pipeline whose shader emits *straight* alpha.
    ///
    /// The built-in quad shader premultiplies before it returns, so it wants the premultiplied
    /// factors. A wallpaper's own shader does not: `gl_FragColor = texSample2D(...)` hands back
    /// exactly what was sampled, which is how Wallpaper Engine's shaders are written and why
    /// its "normal" mode is a plain src-alpha blend. Giving that output `.one` for source RGB
    /// counts the colour once at full strength and again through the destination term, so
    /// anything drawn over a light background saturates — every material and every effect pass
    /// was blowing out towards white.
    static func materialBlendMode(named name: String?) -> BlendMode {
        switch name?.lowercased() {
        case "additive": .additive
        case "multiply": .multiply
        case "screen": .screen
        case "normal", "translucent", .none: .alphaBlend
        default: .alphaBlend
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
            // A constant `false` can never show, so it is not worth compiling. A property-bound
            // effect is compiled whatever its current state: the user can switch it on at any
            // moment, and it has to be ready when they do.
            let binding = effect.visible.flatMap { $0.isUserBound ? $0 : nil }
            if binding == nil, let visible = effect.visible?.staticValue, !visible { continue }
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
                   for: document, instance: effect, assets: assets, device: device, report: &report
               ) {
                resolved.append(LayerEffect(.compiled(compiled), visibility: binding))
                continue
            }

            if let post = Self.postEffect(for: document) {
                resolved.append(LayerEffect(.builtIn(post), visibility: binding))
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
        var textBindings: [TextBinding] = []
        var animationBindings: [AnimationBinding] = []
        var scriptRuntime: ScriptRuntime?

        func bindAnimations(of object: SceneObject, to layer: RenderableLayer, at index: Int) {
            for (property, animation) in object.animations.sorted(by: { $0.key < $1.key }) {
                let base: SIMD4<Float> = switch property {
                case "origin": SIMD4(layer.origin, 0)
                case "angles": SIMD4(layer.angles, 0)
                case "scale": SIMD4(layer.scale, 0)
                default: layer.tint
                }
                animationBindings.append(
                    AnimationBinding(layerIndex: index, property: property, animation: animation, base: base)
                )
            }
        }

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
                    bindAnimations(of: object, to: layer, at: layerIndex)

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
                        if let handle = runtime.compile(
                            body, name: "\(layer.name).\(property)",
                            properties: object.scriptProperties[property] ?? [:]
                        ) {
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
                if let built = buildTextLayer(
                    object, layerIndex: layers.count, assets: assets, device: device,
                    runtime: &scriptRuntime, report: &report
                ) {
                    bindAnimations(of: object, to: built.layer, at: layers.count)
                    layers.append(built.layer)
                    if let binding = built.binding { textBindings.append(binding) }
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
            textBindings: textBindings,
            animationBindings: animationBindings,
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
            if let texturePath = pass.primaryTexture,
               let loaded = assets.sceneTexture(at: texturePath, device: device) {
                system.texture = loaded.texture
                system.sprite = loaded.sprite
            }
        }

        // Surface whatever behaviours the emitter needed and we do not implement.
        for finding in system.findings { report.add(finding) }
        return system
    }

    private func buildTextLayer(
        _ object: SceneObject,
        layerIndex: Int,
        assets: SceneAssets,
        device: any MTLDevice,
        runtime: inout ScriptRuntime?,
        report: inout CompatibilityReport
    ) -> (layer: RenderableLayer, binding: TextBinding?)? {
        var findings: [CompatibilityFinding] = []
        let renderer = TextLayerRenderer()
        defer { for finding in findings { report.add(finding) } }

        guard let style = renderer.style(for: object, assets: assets, findings: &findings) else {
            report.add(
                .degraded, feature: "Text layer",
                detail: object.name.map { "\"\($0)\" could not be rendered" }
            )
            return nil
        }

        // A scripted text layer — every clock and date in a real library — shows what its
        // script says from the first frame, not the placeholder the editor saved beside it.
        var text = object.text ?? ""
        var binding: TextBinding?
        if let body = object.scripts["text"] {
            if runtime == nil { runtime = ScriptRuntime() }
            if let runtime, let handle = runtime.compile(
                body, name: "\(object.name ?? "Text").text",
                properties: object.scriptProperties["text"] ?? [:]
            ) {
                if case .string(let first)? = runtime.evaluate(
                    handle: handle, current: .string(text), deltaTime: 0, elapsed: 0
                ) {
                    text = first
                }
                binding = TextBinding(layerIndex: layerIndex, handle: handle, style: style, text: text)
            }
        }

        guard let rendered = renderer.makeTexture(text: text, style: style, device: device) else {
            report.add(
                .degraded, feature: "Text layer",
                detail: object.name.map { "\"\($0)\" could not be rendered" }
            )
            return nil
        }

        let origin = object.origin ?? WEVector3(0, 0, 0)
        let angles = object.angles ?? WEVector3(0, 0, 0)
        let scale = object.scale ?? WEVector3(1, 1, 1)
        let parallax = object.parallaxDepth

        // Size comes from the rasterised bitmap, not from the object's declared size: the text
        // has a real aspect ratio and forcing it into a declared box would stretch the glyphs.
        var layer = RenderableLayer(
            name: object.name ?? "Text",
            origin: SIMD3(Float(origin.x), Float(origin.y), Float(origin.z)),
            angles: SIMD3(
                Float(angles.x),
                Float(angles.y),
                Float(angles.z)
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
        layer.visibilityBinding = object.visible.flatMap { $0.isUserBound ? $0 : nil }
        return (layer, binding)
    }

    private func buildImageLayer(
        _ object: SceneObject,
        assets: SceneAssets,
        device: any MTLDevice,
        materials: MaterialCompiler?,
        report: inout CompatibilityReport
    ) -> RenderableLayer? {
        guard let imagePath = object.image else { return nil }
        guard let resolved = assets.resolvedMaterial(forImage: imagePath) else { return nil }
        guard let pass = resolved.material.firstPass else {
            report.add(.degraded, feature: "Material", detail: "\(imagePath) declares no passes")
            return nil
        }
        let material = resolved.material

        var loaded: SceneTexture?
        if let texturePath = pass.primaryTexture {
            loaded = assets.sceneTexture(at: texturePath, device: device)
        }
        let texture = loaded?.texture

        // Fall back to the texture's own dimensions when the object does not state a size, which
        // is the common case for a layer that is simply its image at natural scale.
        let size: SIMD2<Float>
        if let declared = object.size {
            size = SIMD2(Float(declared.x), Float(declared.y))
        } else if let frameSize = loaded?.sprite?.frameSize {
            // One frame of an animation, not the atlas holding all of them.
            size = frameSize
        } else if let loaded {
            // The image, not the allocation: a padded texture would otherwise make a layer
            // measured in power-of-two pixels, roughly twice the size the author drew.
            size = loaded.imageSize
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
            primaryTexture: loaded, materials: materials, report: &report
        )

        // A material that names a texture it cannot have is not a solid-colour layer, and
        // drawing it through the built-in shader as one put a white rectangle over the
        // wallpaper. The material's own shader, when it compiled, decides for itself what to
        // draw without it. Why the texture is missing is already in the report.
        if pass.primaryTexture != nil, loaded == nil, compiled == nil {
            report.add(
                .degraded, feature: "Layer",
                detail: "\"\(object.name ?? imagePath)\" is hidden because its texture could not be loaded"
            )
            return nil
        }

        var layer = RenderableLayer(
            name: object.name ?? imagePath,
            origin: SIMD3(Float(origin.x), Float(origin.y), Float(origin.z)),
            angles: SIMD3(
                Float(angles.x),
                Float(angles.y),
                Float(angles.z)
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
        layer.materialTextureSizes = compiled?.sizes ?? [:]
        layer.materialRepeatingTextures = compiled?.repeating ?? []
        layer.materialConstants = pass.constantShaderValues
        layer.uvScale = loaded?.uvScale ?? SIMD2(1, 1)
        layer.sprite = loaded?.sprite
        layer.spriteFrame = loaded?.sprite?.frames.first
        layer.visibilityBinding = object.visible.flatMap { $0.isUserBound ? $0 : nil }
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
        primaryTexture: SceneTexture?,
        materials: MaterialCompiler?,
        report: inout CompatibilityReport
    ) -> (
        program: MaterialProgram,
        textures: [String: any MTLTexture],
        sizes: [String: SIMD4<Float>],
        repeating: Set<String>
    )? {
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
            if case ShaderFileProviderError.notFound(let file) = error {
                // By far the common case: every scene in a real library names
                // `genericimage2`, which ships inside Wallpaper Engine rather than the wallpaper.
                report.add(
                    .degraded, feature: "Shader",
                    detail: "\(shader): \(file) ships with Wallpaper Engine rather than the "
                        + "wallpaper — drawn with a built-in approximation"
                )
            } else {
                report.add(
                    .degraded, feature: "Shader",
                    detail: "\(shader): \(ShaderMessageText.oneLine(error.localizedDescription)) — drawn without it"
                )
            }
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
        var sizes: [String: SIMD4<Float>] = [:]
        var repeating: Set<String> = []
        func bind(_ loaded: SceneTexture, to sampler: String) {
            textures[sampler] = loaded.texture
            sizes[sampler] = loaded.resolution
            if loaded.repeats { repeating.insert(sampler) }
        }
        for (index, path) in pass.textures.enumerated() {
            let samplerName = Self.samplerName(
                forTextureSlot: index, declared: program.declaredSamplers
            )
            if index == 0, let primaryTexture {
                bind(primaryTexture, to: samplerName)
                continue
            }
            guard let path, !path.isEmpty else { continue }
            if let loaded = assets.sceneTexture(at: path, device: device) {
                bind(loaded, to: samplerName)
            }
        }
        if textures.isEmpty, let primaryTexture, let first = program.declaredSamplers.first {
            bind(primaryTexture, to: first)
        }
        // Anything still unassigned reads its annotation's default, as it would in Wallpaper
        // Engine. Left unbound it read the white placeholder instead — harmless for a mask
        // that defaults to `util/white`, but a flow map that defaults to `util/noflow` reads
        // white as full-strength motion.
        for name in program.declaredSamplers where textures[name] == nil {
            guard let reference = program.samplerDefaults[name],
                  let loaded = assets.sceneTexture(at: reference, device: device)
            else { continue }
            bind(loaded, to: name)
        }

        return (program, textures, sizes, repeating)
    }
}

/// A loaded texture together with the size of the image inside it.
///
/// Wallpaper Engine pads textures up to a power of two, so the allocation is routinely larger
/// than the picture it holds. The two sizes are what `g_TextureNResolution` reports to a
/// shader — `xy` the allocation, `zw` the image — and what the built-in quad path needs to
/// build a UV rectangle that stops at the edge of the content.
public struct SceneTexture {
    public let texture: any MTLTexture
    public let imageSize: SIMD2<Float>
    /// Whether sampling outside 0..1 wraps around. Authors choose per texture — every painted
    /// mask in the test library clamps, while 30 layer textures and 15 effect assets are
    /// marked to tile — and noise is sampled far outside 0..1 on purpose, so one address mode
    /// for everything is wrong for someone.
    public let repeats: Bool
    /// Frames, when the texture is an animation; `texture` is then its first page.
    public let sprite: SpriteAnimation?

    public init(
        texture: any MTLTexture, imageSize: SIMD2<Float>, repeats: Bool = false,
        sprite: SpriteAnimation? = nil
    ) {
        self.texture = texture
        self.imageSize = imageSize
        self.repeats = repeats
        self.sprite = sprite
    }

    /// The whole allocation, padding included.
    public var allocationSize: SIMD2<Float> {
        SIMD2(Float(texture.width), Float(texture.height))
    }

    /// The fraction of the allocation the image occupies, which is the UV it ends at.
    public var uvScale: SIMD2<Float> {
        SIMD2(imageSize.x / max(allocationSize.x, 1), imageSize.y / max(allocationSize.y, 1))
    }

    /// `g_TextureNResolution`: allocation in `xy`, image in `zw`.
    public var resolution: SIMD4<Float> {
        SIMD4(allocationSize.x, allocationSize.y, imageSize.x, imageSize.y)
    }
}
