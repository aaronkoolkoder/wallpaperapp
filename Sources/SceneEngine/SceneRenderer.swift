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
    private var camera = CameraMotion()

    /// Pointer position normalised to [-1, 1] about the screen centre. Set by the backend each
    /// frame; the renderer itself never touches AppKit.
    public var pointer: SIMD2<Float> = .zero

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

    public func render(to layer: CAMetalLayer, timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard let scene else { return }
        guard let drawable = layer.nextDrawable() else { return }

        clock.advance(to: timestamp)
        camera.setPointer(normalized: pointer)
        camera.update(deltaTime: clock.delta)
        let cameraOffset = camera.offset
        runScripts(scene: scene)

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(scene.clearColor.x),
            green: Double(scene.clearColor.y),
            blue: Double(scene.clearColor.z),
            alpha: 1
        )

        // The encoder is created inside whichever path runs. Creating one here and leaving it
        // unended on the effects path is a Metal API violation, not merely wasteful.
        guard let buffer = renderDevice.makeFrameCommandBuffer(label: "scene") else { return }

        // Aspect-fill the scene's ortho box into the drawable. Letterboxing a wallpaper would
        // show bars at the edges of the desktop, which is never what anyone wants.
        let projection = aspectFilledProjection(
            scene: scene,
            drawableSize: SIMD2(Float(drawable.texture.width), Float(drawable.texture.height))
        )

        let hasEffects = !scene.sceneEffects.isEmpty
            || workingLayers.contains { !$0.effects.isEmpty }

        if !hasEffects {
            // Fast path. Most scenes have no post-processing, and routing them through an
            // intermediate target would cost a full-frame copy for nothing.
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }
            buildDraws(scene: scene, cameraOffset: cameraOffset, into: &drawScratch)
            encodeDraws(
                drawScratch, into: encoder, projection: projection, pixelFormat: layer.pixelFormat
            )
            encoder.endEncoding()
        } else {
            renderWithEffects(
                scene: scene,
                cameraOffset: cameraOffset,
                projection: projection,
                drawable: drawable,
                clear: descriptor.colorAttachments[0].clearColor,
                buffer: buffer
            )
        }

        buffer.present(drawable)
        buffer.commit()

        pool.endFrame()
        framesRendered &+= 1
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
            if case .builtIn = step, case .builtIn = groups.last?.last {
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

            if case .compiled(let effect) = group[0], group.count == 1 {
                let ran = effectRunner.run(
                    effect, source: current, destination: target,
                    engine: engineUniforms(), commandBuffer: buffer, pool: pool
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

    /// Fill `draws` with every visible layer and particle, in composition order.
    private func buildDraws(
        scene: RenderableScene, cameraOffset: SIMD2<Float>, into draws: inout [SceneDraw]
    ) {
        draws.removeAll(keepingCapacity: true)
        for sceneLayer in workingLayers where sceneLayer.isVisible {
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
                tint: layer.tint,
                texture: layer.texture,
                blend: layer.blend
            ),
            program: layer.program,
            textures: layer.materialTextures,
            constants: layer.materialConstants
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
        drawable: any CAMetalDrawable,
        clear: MTLClearColor,
        buffer: any MTLCommandBuffer
    ) {
        let width = drawable.texture.width
        let height = drawable.texture.height

        guard let accumulator = pool.acquire(
            width: width, height: height, pixelFormat: drawable.texture.pixelFormat
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

        for sceneLayer in workingLayers where sceneLayer.isVisible {
            let draw = Self.sceneDraw(for: sceneLayer, cameraOffset: cameraOffset)

            guard !sceneLayer.effects.isEmpty else {
                batch.append(draw)
                continue
            }

            // Flush everything queued behind this layer so ordering survives.
            drawBatch(batch, into: accumulator.texture, clearFirst: isFirstWrite)
            if !batch.isEmpty || isFirstWrite { isFirstWrite = false }
            batch.removeAll(keepingCapacity: true)

            guard let isolated = pool.acquire(
                width: width, height: height, pixelFormat: drawable.texture.pixelFormat
            ), let processed = pool.acquire(
                width: width, height: height, pixelFormat: drawable.texture.pixelFormat
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
                sceneLayer.effects,
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

        // Scene-wide chain straight into the drawable.
        applyEffectChain(
            scene.sceneEffects,
            source: accumulator.texture,
            destination: drawable.texture,
            buffer: buffer
        )
    }

    /// A quad that exactly covers the frame under the scene's projection.
    ///
    /// The composite step needs to blit a processed layer back in the same coordinate space the
    /// rest of the scene draws in, so it has to be expressed as a quad rather than a blit.
    static func fullscreenTransform(projection: simd_float4x4) -> simd_float4x4 {
        let halfWidth = 1 / max(0.000001, projection.columns.0.x)
        let halfHeight = 1 / max(0.000001, projection.columns.1.y)
        return simd_float4x4(diagonal: SIMD4(halfWidth * 2, halfHeight * 2, 1, 1))
    }

    /// Scale the scene so it covers the drawable, cropping the longer axis rather than letting
    /// the aspect ratios diverge and stretching the image.
    private func aspectFilledProjection(
        scene: RenderableScene, drawableSize: SIMD2<Float>
    ) -> simd_float4x4 {
        var projection = scene.projectionMatrix
        guard drawableSize.x > 0, drawableSize.y > 0 else { return projection }

        let sceneAspect = scene.orthoSize.x / max(1, scene.orthoSize.y)
        let targetAspect = drawableSize.x / drawableSize.y

        if targetAspect > sceneAspect {
            // Drawable is wider: match width, crop height.
            projection.columns.1.y *= sceneAspect / targetAspect
        } else {
            projection.columns.0.x *= targetAspect / sceneAspect
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

        guard let target = renderDevice.device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        // Effects need somewhere to read from, so composition goes to an intermediate whenever
        // the scene post-processes. Rendering straight to `target` would silently skip the
        // chain — which is exactly the bug this path had: the headless harness was exercising a
        // different pipeline from the app, so bloom rendered live but not in tests.
        let hasEffects = !scene.sceneEffects.isEmpty
            || scene.layers.contains { !$0.effects.isEmpty }

        var intermediate: PooledTexture?
        if hasEffects {
            intermediate = pool.acquire(width: width, height: height, pixelFormat: .bgra8Unorm)
        }
        defer { if let intermediate { pool.release(intermediate) } }
        let compositionTarget: any MTLTexture = intermediate?.texture ?? target

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = compositionTarget
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(scene.clearColor.x),
            green: Double(scene.clearColor.y),
            blue: Double(scene.clearColor.z),
            alpha: 1
        )

        guard let buffer = renderDevice.makeRetainedCommandBuffer(label: "offscreen"),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return nil }

        let projection = aspectFilledProjectionForTesting(
            scene: scene, drawableSize: SIMD2(Float(width), Float(height))
        )

        var draws = workingLayers.filter(\.isVisible).map { layer in
            Self.sceneDraw(for: layer, cameraOffset: cameraOffset)
        }
        var particles: [QuadDraw] = []
        for system in scene.particles {
            system.appendDraws(to: &particles, cameraOffset: cameraOffset)
        }
        draws.append(contentsOf: particles.map { SceneDraw(quad: $0, program: nil) })

        // The same dispatcher the live path uses. A harness that drew through a different
        // pipeline would verify something the app never renders — which has already been a bug
        // here once, when effects were skipped offscreen.
        encodeDraws(draws, into: encoder, projection: projection, pixelFormat: .bgra8Unorm)
        encoder.endEncoding()

        if hasEffects, intermediate != nil {
            // Per-layer chains are folded into the scene chain here. This path is a diagnostic,
            // and reproducing exact per-layer isolation would mean duplicating the whole live
            // composition path for no extra diagnostic value.
            let combined = scene.layers.flatMap(\.effects) + scene.sceneEffects
            applyEffectChain(
                combined,
                source: compositionTarget,
                destination: target,
                buffer: buffer
            )
        }

        buffer.commit()
        buffer.waitUntilCompleted()
        pool.endFrame()

        return Self.makeImage(from: target)
    }

    private func aspectFilledProjectionForTesting(
        scene: RenderableScene, drawableSize: SIMD2<Float>
    ) -> simd_float4x4 {
        var projection = scene.projectionMatrix
        guard drawableSize.x > 0, drawableSize.y > 0 else { return projection }
        let sceneAspect = scene.orthoSize.x / max(1, scene.orthoSize.y)
        let targetAspect = drawableSize.x / drawableSize.y
        if targetAspect > sceneAspect {
            projection.columns.1.y *= sceneAspect / targetAspect
        } else {
            projection.columns.0.x *= targetAspect / sceneAspect
        }
        return projection
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
