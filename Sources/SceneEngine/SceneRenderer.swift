import CoreGraphics
import Diagnostics
import Foundation
import Metal
import MetalRenderer
import QuartzCore
import WEFormat
import simd
import os

/// Draws a ``RenderableScene`` into a Metal layer.
///
/// M4 scope: layered image objects composited in declaration order with their material's blend
/// mode. Effect chains, particles, text and SceneScript come later; the compatibility report
/// carried on the scene already says which of those a given wallpaper needed.
public final class SceneRenderer {
    /// One draw, plus whatever it needs if it runs the material's own shader.
    ///
    /// Carried together rather than split into two lists because composition order is the whole
    /// point: a layer drawn out of turn appears in front of something it should be behind.
    struct SceneDraw {
        var quad: QuadDraw
        var program: MaterialProgram?
        var textures: [String: any MTLTexture] = [:]
        var constants: [String: DynamicValue] = [:]
        /// `g_TextureNResolution` per sampler, which a padded texture makes differ from the
        /// allocation the renderer could otherwise infer on its own.
        var textureSizes: [String: SIMD4<Float>] = [:]
        /// Samplers whose texture tiles.
        var repeatingTextures: Set<String> = []
    }

    private let renderDevice: RenderDevice
    private let quads: QuadRenderer
    private let materials: MaterialRenderer
    private let effectRunner: EffectChainRunner
    private let post: PostProcessor
    private let pool: FBOPool
    private let log = Logger(subsystem: "app.diorama", category: "scene-render")

    /// Reserved uniform names shaders asked for that this app does not supply, collected once
    /// rather than per frame so the log does not fill up.
    public private(set) var unsuppliedEngineUniforms: Set<String> = []

    public private(set) var scene: RenderableScene?
    public private(set) var framesRendered: UInt64 = 0

    /// Scene time and camera state, advanced once per frame.
    public private(set) var clock = SceneClock()

    /// What each scripted text layer shows now, keyed by layer index. Redrawn only when its
    /// script's answer changes, and applied every frame so it survives `workingLayers` being
    /// rebuilt from the scene.
    private var textShown: [Int: (text: String, texture: any MTLTexture, size: SIMD2<Float>)] = [:]
    private var nextTextUpdate: Float = 0
    private var camera = CameraMotion()

    /// Pointer position normalised to [-1, 1] about the screen centre. Set by the backend each
    /// frame; the renderer itself never touches AppKit.
    public var pointer: SIMD2<Float> = .zero

    /// The user's settings for this wallpaper, keyed as `project.json` keys them.
    ///
    /// Applied per draw rather than baked into the scene, so changing one takes effect on the
    /// next frame. Rebuilding the scene for every tick of a slider would recompile shaders and
    /// reload textures to change one float.
    public var propertyOverrides: [String: DynamicValue] = [:]

    /// Latest analysed system audio. Silent unless the user has enabled audio reactivity.
    public var audio: AudioFrame = .silent

    /// Reused across frames. Particle emitters can produce thousands of draws, and rebuilding
    /// this array every frame would allocate on the render path — exactly what PLAN.md §6.2
    /// forbids.
    private var drawScratch: [SceneDraw] = []

    /// Scratch for a run of consecutive draws that share the built-in shader, so batching
    /// survives the dispatch between the two paths.
    private var batchScratch: [QuadDraw] = []

    /// Reused per frame for the same reason: emitters produce thousands of quads.
    private var particleScratch: [QuadDraw] = []

    /// Layers as scripts have most recently left them. Refreshed from the scene when it is set,
    /// then mutated in place each frame so the scene itself stays immutable.
    private var workingLayers: [RenderableLayer] = []

    public init(renderDevice: RenderDevice) throws {
        self.renderDevice = renderDevice
        self.quads = try QuadRenderer(device: renderDevice.device)
        let materialRenderer = try MaterialRenderer(device: renderDevice.device)
        self.materials = materialRenderer
        self.effectRunner = EffectChainRunner(materials: materialRenderer)
        self.post = try PostProcessor(device: renderDevice.device)
        self.pool = FBOPool(device: renderDevice.device)
    }

    public func setScene(_ scene: RenderableScene) {
        self.scene = scene
        camera = scene.cameraMotion
        workingLayers = scene.layers
        textShown = [:]
        nextTextUpdate = 0
        clock.reset()
        log.info(
            "scene ready: \(scene.layers.count) layer(s), parallax \(scene.cameraMotion.isEnabled ? "on" : "off")"
        )
    }

    /// Load, build and hand over a scene in one step.
    public static func loadScene(
        directory: URL,
        packageURL: URL?,
        wallpaperID: String,
        device: any MTLDevice,
        materials: MaterialCompiler? = nil,
        compileMaterials: Bool = true
    ) throws -> RenderableScene {
        let assets = SceneAssets(
            wallpaperID: wallpaperID, directory: directory, packageURL: packageURL
        )
        guard let sceneData = assets.data(for: "scene.json") else {
            throw SceneError.missingSceneDocument
        }
        let document = try JSONDecoder().decode(SceneDocument.self, from: sceneData)
        // `compileMaterials: false` draws every layer through the built-in quad shader, which
        // is what the renderer did before the transpiler. Kept reachable so the cost of running
        // a wallpaper's own shaders can be measured rather than argued about.
        return SceneBuilder().build(
            document: document, assets: assets, device: device,
            materials: materials ?? (compileMaterials ? MaterialCompiler(device: device) : nil)
        )
    }

    /// Why the last `render(to:)` did or did not produce a frame.
    ///
    /// Every way this function gives up is a silent one — the desktop simply stays as it was —
    /// so the reason is recorded rather than inferred. A scene that never draws its first frame
    /// looks identical to a working suspended wallpaper from the outside.
    public enum RenderOutcome: String, Sendable {
        case rendered
        case noScene
        case noDrawable
        case noCommandBuffer
        case noEncoder
    }

    public private(set) var lastOutcome: RenderOutcome = .noScene

    public func render(to layer: CAMetalLayer, timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard let scene else { lastOutcome = .noScene; return }
        guard let drawable = layer.nextDrawable() else { lastOutcome = .noDrawable; return }

        clock.advance(to: timestamp)
        camera.setPointer(normalized: pointer)
        camera.update(deltaTime: clock.delta)
        let cameraOffset = camera.offset
        runScripts(scene: scene)
        runTextScripts(scene: scene)
        advanceSprites()

        guard let buffer = renderDevice.makeFrameCommandBuffer(label: "scene") else {
            lastOutcome = .noCommandBuffer
            return
        }
        guard compose(scene: scene, cameraOffset: cameraOffset, into: drawable.texture, buffer: buffer)
        else {
            lastOutcome = .noEncoder
            return
        }

        buffer.present(drawable)
        buffer.commit()

        pool.endFrame()
        framesRendered &+= 1
        lastOutcome = .rendered
    }

    /// Draws one frame of `scene` into `target`.
    ///
    /// The single place a frame is composed. The desktop hands it a drawable's texture and the
    /// offscreen harness hands it a readable one — and nothing else differs. The harness used to
    /// have a composition of its own that folded every layer's effects into one scene-wide
    /// chain, and so for as long as it existed it could not see the per-layer path at all:
    /// the one wallpapers with a layer effect actually take on the desktop.
    ///
    /// - Returns: false when no encoder could be made, so the frame was not drawn.
    private func compose(
        scene: RenderableScene,
        cameraOffset: SIMD2<Float>,
        into target: any MTLTexture,
        buffer: any MTLCommandBuffer
    ) -> Bool {
        let clear = MTLClearColor(
            red: Double(scene.clearColor.x),
            green: Double(scene.clearColor.y),
            blue: Double(scene.clearColor.z),
            alpha: 1
        )
        // Aspect-fill the scene's ortho box into the target. Letterboxing a wallpaper would
        // show bars at the edges of the desktop, which is never what anyone wants.
        let projection = Self.aspectFilledProjection(
            scene: scene,
            drawableSize: SIMD2(Float(target.width), Float(target.height))
        )

        // Only what is actually running counts: a scene whose sole effect is an optional one
        // the user has switched off should take the fast path, not pay for an accumulator.
        let hasEffects = !scene.sceneEffects.active(with: propertyOverrides).isEmpty
            || workingLayers.contains {
                $0.isShown(with: propertyOverrides) && !$0.effects.active(with: propertyOverrides).isEmpty
            }

        if hasEffects {
            renderWithEffects(
                scene: scene, cameraOffset: cameraOffset, projection: projection,
                target: target, clear: clear, buffer: buffer
            )
            return true
        }

        // Fast path. Most scenes have no post-processing, and routing them through an
        // intermediate target would cost a full-frame copy for nothing. The encoder is made
        // here rather than by the caller: one left unended on the effects path would be a
        // Metal API violation, not merely waste.
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clear
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }
        buildDraws(scene: scene, cameraOffset: cameraOffset, into: &drawScratch)
        encodeDraws(drawScratch, into: encoder, projection: projection, pixelFormat: target.pixelFormat)
        encoder.endEncoding()
        return true
    }

    /// Encodes draws in order, switching between the built-in shader and each material's own.
    ///
    /// Consecutive draws that share the built-in shader are still batched; a draw with its own
    /// program flushes the batch first so nothing is reordered around it.
    private func encodeDraws(
        _ draws: [SceneDraw],
        into encoder: any MTLRenderCommandEncoder,
        projection: simd_float4x4,
        pixelFormat: MTLPixelFormat
    ) {
        guard !draws.isEmpty else { return }
        batchScratch.removeAll(keepingCapacity: true)

        func flush() {
            guard !batchScratch.isEmpty else { return }
            quads.encode(
                batchScratch, into: encoder, projection: projection, pixelFormat: pixelFormat
            )
            batchScratch.removeAll(keepingCapacity: true)
        }

        for draw in draws {
            guard let program = draw.program else {
                batchScratch.append(draw.quad)
                continue
            }
            flush()
            let unsupplied = materials.encode(
                program,
                context: MaterialRenderer.DrawContext(
                    transform: draw.quad.transform,
                    projection: projection,
                    textures: draw.textures,
                    constants: draw.constants,
                    textureSizes: draw.textureSizes,
                    repeatingTextures: draw.repeatingTextures,
                    overrides: propertyOverrides,
                    engine: engineUniforms()
                ),
                into: encoder
            )
            if !unsupplied.isEmpty { unsuppliedEngineUniforms.formUnion(unsupplied) }
        }
        flush()
    }

    /// Runs a chain of effects in order, whichever kind each step is.
    ///
    /// Consecutive approximated steps go through `PostProcessor` in one call, which already
    /// ping-pongs internally; each compiled effect runs its own passes. Grouping preserves the
    /// author's order — running all of one kind and then the other would change the result of
    /// any chain that mixes them.
    private func applyEffectChain(
        _ chain: [LayerEffect],
        source: any MTLTexture,
        destination: any MTLTexture,
        buffer: any MTLCommandBuffer
    ) {
        guard !chain.isEmpty else {
            post.apply([], source: source, destination: destination, commandBuffer: buffer, pool: pool)
            return
        }

        // Group into runs so a sequence of approximated steps stays one call.
        var groups: [[LayerEffect]] = []
        for step in chain {
            if case .builtIn = step.implementation, case .builtIn = groups.last?.last?.implementation {
                groups[groups.count - 1].append(step)
            } else {
                groups.append([step])
            }
        }

        var current: any MTLTexture = source
        var scratch: PooledTexture?
        defer { if let scratch { pool.release(scratch) } }

        for (index, group) in groups.enumerated() {
            let isLast = index == groups.count - 1
            let target: any MTLTexture
            if isLast {
                target = destination
            } else {
                guard let pooled = pool.acquire(
                    width: destination.width, height: destination.height,
                    pixelFormat: destination.pixelFormat
                ) else {
                    // Out of memory mid-chain: emit what we have rather than a black frame,
                    // matching what PostProcessor does in the same situation.
                    post.apply(
                        [], source: current, destination: destination,
                        commandBuffer: buffer, pool: pool
                    )
                    return
                }
                if let previous = scratch { pool.release(previous) }
                scratch = pooled
                target = pooled.texture
            }

            if case .compiled(let effect) = group[0].implementation, group.count == 1 {
                let ran = effectRunner.run(
                    effect, source: current, destination: target,
                    overrides: propertyOverrides, engine: engineUniforms(),
                    commandBuffer: buffer, pool: pool
                )
                if !ran {
                    post.apply(
                        [], source: current, destination: target,
                        commandBuffer: buffer, pool: pool
                    )
                }
            } else {
                post.apply(
                    group.builtInOnly, source: current, destination: target,
                    commandBuffer: buffer, pool: pool
                )
            }
            current = target
        }
    }

    /// The values the app supplies to every shader this frame.
    private func engineUniforms() -> EngineUniforms {
        EngineUniforms(
            time: Float(clock.elapsed),
            dayTime: Self.dayTimeFraction(),
            pointerPosition: pointer,
            audioSpectrumLeft: Self.spectrum16(from: audio.left),
            audioSpectrumRight: Self.spectrum16(from: audio.right)
        )
    }

    /// Folds the analyser's 64 bands into the 16 Wallpaper Engine shaders declare.
    ///
    /// Averaged rather than sampled every fourth band: a shader reacting to a narrow band would
    /// otherwise miss energy that lands in the three bands next to it and look unresponsive.
    static func spectrum16(from bands: [Float]) -> [Float] {
        let target = 16
        guard bands.count >= target else {
            return bands + [Float](repeating: 0, count: target - bands.count)
        }
        let group = bands.count / target
        return (0 ..< target).map { index in
            let slice = bands[(index * group) ..< min((index + 1) * group, bands.count)]
            return slice.isEmpty ? 0 : slice.reduce(0, +) / Float(slice.count)
        }
    }

    /// Time of day as a fraction of 24 hours, which day/night shaders branch on.
    static func dayTimeFraction(now: Date = Date(), calendar: Calendar = .current) -> Float {
        let components = calendar.dateComponents([.hour, .minute, .second], from: now)
        let seconds = (components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60 + (components.second ?? 0)
        return Float(seconds) / 86_400
    }

    /// Evaluate every scripted property for this frame.
    ///
    /// Scripts read the value they last produced, so state accumulates in `workingLayers` rather
    /// than resetting to the authored value each frame — that is what lets a script written as
    /// `return value + speed * deltaTime` actually animate.
    private func runScripts(scene: RenderableScene) {
        guard let runtime = scene.scriptRuntime, !scene.scriptBindings.isEmpty else { return }
        runtime.setAudio(audio)

        for binding in scene.scriptBindings {
            guard binding.layerIndex < workingLayers.count else { continue }
            let current = workingLayers[binding.layerIndex].scriptValue(for: binding.property)
            guard let result = runtime.evaluate(
                handle: binding.handle,
                current: current,
                deltaTime: Double(clock.delta),
                elapsed: Double(clock.elapsed)
            ) else { continue }
            workingLayers[binding.layerIndex].applyScriptValue(result, to: binding.property)
        }
    }

    /// Ask each scripted text layer what it says, and redraw the ones whose answer changed.
    ///
    /// Four times a second is often enough for a clock showing seconds, and a clock showing
    /// minutes redraws once a minute — the rest of the time this is one short script call.
    private func runTextScripts(scene: RenderableScene) {
        guard let runtime = scene.scriptRuntime, !scene.textBindings.isEmpty else { return }
        let now = clock.elapsed
        if now >= nextTextUpdate {
            nextTextUpdate = now + 0.25
            for binding in scene.textBindings {
                let current = textShown[binding.layerIndex]?.text ?? binding.text
                guard case .string(let text)? = runtime.evaluate(
                          handle: binding.handle, current: .string(current),
                          deltaTime: Double(clock.delta), elapsed: Double(now)
                      ),
                      text != current,
                      let drawn = TextLayerRenderer().makeTexture(
                          text: text, style: binding.style, device: renderDevice.device
                      )
                else { continue }
                textShown[binding.layerIndex] = (text, drawn.texture, drawn.size)
            }
        }
        for (index, shown) in textShown where workingLayers.indices.contains(index) {
            workingLayers[index].texture = shown.texture
            workingLayers[index].size = shown.size
        }
    }

    /// Point every animated layer at the frame showing now.
    private func advanceSprites() {
        let now = Float(clock.elapsed)
        for index in workingLayers.indices {
            guard let sprite = workingLayers[index].sprite else { continue }
            let frame = sprite.frame(at: now)
            workingLayers[index].spriteFrame = frame
            workingLayers[index].texture = sprite.texture(for: frame)
        }
    }

    /// Fill `draws` with every visible layer and particle, in composition order.
    private func buildDraws(
        scene: RenderableScene, cameraOffset: SIMD2<Float>, into draws: inout [SceneDraw]
    ) {
        draws.removeAll(keepingCapacity: true)
        for sceneLayer in workingLayers where sceneLayer.isShown(with: propertyOverrides) {
            draws.append(Self.sceneDraw(for: sceneLayer, cameraOffset: cameraOffset))
        }

        // Particles always use the built-in shader: an emitter's material describes the sprite,
        // and the thousands of quads it produces are batched as one draw run.
        particleScratch.removeAll(keepingCapacity: true)
        for system in scene.particles {
            system.update(deltaTime: clock.delta)
            system.appendDraws(to: &particleScratch, cameraOffset: cameraOffset)
        }
        for quad in particleScratch { draws.append(SceneDraw(quad: quad, program: nil)) }
    }

    static func sceneDraw(for layer: RenderableLayer, cameraOffset: SIMD2<Float>) -> SceneDraw {
        SceneDraw(
            quad: QuadDraw(
                transform: layer.modelMatrix(cameraOffset: cameraOffset),
                // Stop at the edge of the image. A Wallpaper Engine texture is padded up to a
                // power of two, so sampling the full 0..1 draws the empty margin as content and
                // shrinks the picture into a corner of the surface.
                uvRect: layer.uvRect,
                tint: layer.tint,
                texture: layer.texture,
                blend: layer.blend
            ),
            program: layer.program,
            textures: layer.materialTextures,
            constants: layer.materialConstants,
            textureSizes: layer.materialTextureSizes,
            repeatingTextures: layer.materialRepeatingTextures
        )
    }

    /// Composition path for scenes that post-process.
    ///
    /// Layers carrying their own effect chain are rendered alone into a pooled target, run
    /// through the chain, and composited back in z-order. Everything else draws straight onto the
    /// accumulation target. Preserving order this way is the whole reason for going layer by
    /// layer rather than collecting effected layers and doing them at the end.
    private func renderWithEffects(
        scene: RenderableScene,
        cameraOffset: SIMD2<Float>,
        projection: simd_float4x4,
        target: any MTLTexture,
        clear: MTLClearColor,
        buffer: any MTLCommandBuffer
    ) {
        let width = target.width
        let height = target.height

        guard let accumulator = pool.acquire(
            width: width, height: height, pixelFormat: target.pixelFormat
        ) else { return }
        defer { pool.release(accumulator) }

        var isFirstWrite = true

        func drawBatch(_ draws: [SceneDraw], into target: any MTLTexture, clearFirst: Bool) {
            guard !draws.isEmpty || clearFirst else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = clearFirst ? .clear : .load
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = clearFirst
                ? clear
                : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encodeDraws(
                draws, into: encoder, projection: projection, pixelFormat: target.pixelFormat
            )
            encoder.endEncoding()
        }

        var batch: [SceneDraw] = []

        for sceneLayer in workingLayers where sceneLayer.isShown(with: propertyOverrides) {
            let draw = Self.sceneDraw(for: sceneLayer, cameraOffset: cameraOffset)
            let effects = sceneLayer.effects.active(with: propertyOverrides)

            guard !effects.isEmpty else {
                batch.append(draw)
                continue
            }

            // Flush everything queued behind this layer so ordering survives.
            drawBatch(batch, into: accumulator.texture, clearFirst: isFirstWrite)
            if !batch.isEmpty || isFirstWrite { isFirstWrite = false }
            batch.removeAll(keepingCapacity: true)

            guard let isolated = pool.acquire(
                width: width, height: height, pixelFormat: target.pixelFormat
            ), let processed = pool.acquire(
                width: width, height: height, pixelFormat: target.pixelFormat
            ) else {
                // No memory for the chain: draw the layer unprocessed rather than dropping it.
                batch.append(draw)
                continue
            }

            let isolatedPass = MTLRenderPassDescriptor()
            isolatedPass.colorAttachments[0].texture = isolated.texture
            isolatedPass.colorAttachments[0].loadAction = .clear
            isolatedPass.colorAttachments[0].storeAction = .store
            isolatedPass.colorAttachments[0].clearColor = MTLClearColor(
                red: 0, green: 0, blue: 0, alpha: 0
            )
            if let encoder = buffer.makeRenderCommandEncoder(descriptor: isolatedPass) {
                encodeDraws(
                    [draw], into: encoder, projection: projection,
                    pixelFormat: isolated.texture.pixelFormat
                )
                encoder.endEncoding()
            }

            applyEffectChain(
                effects,
                source: isolated.texture,
                destination: processed.texture,
                buffer: buffer
            )

            // Composite the processed layer back, full-frame.
            let composite = SceneDraw(
                quad: QuadDraw(
                    transform: Self.fullscreenTransform(projection: projection),
                    texture: processed.texture,
                    blend: .premultipliedAlpha
                ),
                // The layer's own shader already ran into the isolated target; compositing the
                // result is a straight blit and must not run it a second time.
                program: nil
            )
            drawBatch([composite], into: accumulator.texture, clearFirst: false)

            pool.release(isolated)
            pool.release(processed)
        }

        drawBatch(batch, into: accumulator.texture, clearFirst: isFirstWrite)
        if isFirstWrite { isFirstWrite = false }

        // Particles last, straight onto the accumulator.
        var particleDraws: [QuadDraw] = []
        for system in scene.particles {
            system.update(deltaTime: clock.delta)
            system.appendDraws(to: &particleDraws, cameraOffset: cameraOffset)
        }
        drawBatch(
            particleDraws.map { SceneDraw(quad: $0, program: nil) },
            into: accumulator.texture, clearFirst: false
        )

        // Scene-wide chain straight into the target.
        applyEffectChain(
            scene.sceneEffects.active(with: propertyOverrides),
            source: accumulator.texture,
            destination: target,
            buffer: buffer
        )
    }

    /// A quad that exactly covers the frame under the scene's projection.
    ///
    /// The composite step draws a processed layer back in the same coordinate space the rest of
    /// the scene draws in, so it has to be a quad placed *through* the projection: the unit quad
    /// scaled to clip space's ±1, taken back through the projection's inverse.
    ///
    /// Derived rather than assumed. This used to take only the projection's scale, which is
    /// right only for a projection centred on zero — and the scene projection places its
    /// corner at the origin, with the centre folded into the translation. The quad therefore
    /// landed a full half-frame down and to the left, and every layer with an effect of its own
    /// showed on the desktop as its top-right quarter, in the bottom-left quarter of the screen.
    static func fullscreenTransform(projection: simd_float4x4) -> simd_float4x4 {
        projection.inverse * simd_float4x4(diagonal: SIMD4(2, 2, 1, 1))
    }

    /// Scale the scene so it covers the drawable, cropping the longer axis rather than letting
    /// the aspect ratios diverge and stretching the image.
    /// Aspect-*fill* the scene's ortho box into the target: preserve the scene's aspect ratio
    /// and crop the overflowing axis, rather than stretching or letterboxing.
    ///
    /// Both the axis scale and that axis's translation, because the projection places the
    /// scene's *corner* origin — NDC is `(x - centre) * scale`, with the centre term folded
    /// into column 3. Scaling only column 0 or 1 leaves the centre at its old magnitude, so the
    /// scene slides off-centre and leaves a band of clear colour down one edge.
    static func aspectFilledProjection(
        scene: RenderableScene, drawableSize: SIMD2<Float>
    ) -> simd_float4x4 {
        var projection = scene.projectionMatrix
        guard drawableSize.x > 0, drawableSize.y > 0 else { return projection }

        let sceneAspect = scene.orthoSize.x / max(1, scene.orthoSize.y)
        let targetAspect = drawableSize.x / drawableSize.y

        if targetAspect > sceneAspect {
            // Target is relatively wider: match its width, which overflows vertically.
            let scale = targetAspect / sceneAspect
            projection.columns.1.y *= scale
            projection.columns.3.y *= scale
        } else {
            let scale = sceneAspect / targetAspect
            projection.columns.0.x *= scale
            projection.columns.3.x *= scale
        }
        return projection
    }

    public var poolStatistics: (currentBytes: Int, peakBytes: Int, reuse: Int) {
        (pool.currentBytes, pool.peakBytes, pool.reuseCount)
    }
}

public enum SceneError: Error, LocalizedError {
    case missingSceneDocument

    public var errorDescription: String? {
        switch self {
        case .missingSceneDocument: "This wallpaper contains no scene.json"
        }
    }
}

// MARK: - Offscreen rendering

extension SceneRenderer {
    /// Render one frame to an image, with no window and no display.
    ///
    /// This is the golden-image test harness from PLAN.md §12: it is what turns "handles most
    /// scenes" from a feeling into a number that CI can watch. It also makes scene bugs
    /// debuggable without a wallpaper running on somebody's desktop.
    /// - Parameter pointer: normalised pointer position, so parallax can be exercised without
    ///   a live cursor. Settles the camera immediately rather than easing, since a single
    ///   offscreen frame has no history to ease from.
    /// - Parameter warmUpSeconds: simulate this long before capturing. Particle emitters start
    ///   empty, so a cold single frame of a snow scene renders nothing at all and would make a
    ///   working emitter look broken.
    /// - Parameters:
    ///   - pointer: normalised pointer position, so parallax can be exercised without a live
    ///     cursor. Settles the camera immediately, since a single frame has no history to ease from.
    ///   - warmUpSeconds: simulate this long before capturing. Particle emitters start empty, so
    ///     a cold frame of a snow scene renders nothing and makes a working emitter look broken.
    public func renderOffscreen(
        width: Int, height: Int, pointer: SIMD2<Float> = .zero, warmUpSeconds: Float = 0
    ) -> CGImage? {
        guard let scene else { return nil }

        // Warm up particles AND scripts together. Running only one of them here is how the
        // effects path went wrong earlier: the headless harness silently exercised a different
        // pipeline from the app, so a working feature looked broken in testing.
        if warmUpSeconds > 0 {
            workingLayers = scene.layers
            let step: Float = 1.0 / 60
            var remaining = warmUpSeconds
            while remaining > 0 {
                let dt = min(step, remaining)
                for system in scene.particles { system.update(deltaTime: dt) }
                clock.advanceForTesting(delta: dt)
                runScripts(scene: scene)
                remaining -= dt
            }
        } else if workingLayers.count != scene.layers.count {
            workingLayers = scene.layers
        }
        runTextScripts(scene: scene)
        advanceSprites()

        var camera = scene.cameraMotion
        camera.delay = 0
        camera.setPointer(normalized: pointer)
        camera.update(deltaTime: 0)
        let cameraOffset = camera.offset

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        // Shared, not private: the whole point is to read these pixels back on the CPU.
        descriptor.storageMode = .shared

        guard let target = renderDevice.device.makeTexture(descriptor: descriptor),
              let buffer = renderDevice.makeRetainedCommandBuffer(label: "offscreen"),
              compose(scene: scene, cameraOffset: cameraOffset, into: target, buffer: buffer)
        else { return nil }

        buffer.commit()
        buffer.waitUntilCompleted()
        pool.endFrame()

        return Self.makeImage(from: target)
    }


    static func makeImage(from texture: any MTLTexture) -> CGImage? {
        let width = texture.width, height = texture.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(
                base, bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
            )
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        // BGRA on the GPU; the byte-order flag is what makes CoreGraphics read it correctly
        // rather than producing a red/blue-swapped image.
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
