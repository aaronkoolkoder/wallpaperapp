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
    private let renderDevice: RenderDevice
    private let quads: QuadRenderer
    private let post: PostProcessor
    private let pool: FBOPool
    private let log = Logger(subsystem: "app.diorama", category: "scene-render")

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
    private var drawScratch: [QuadDraw] = []

    /// Layers as scripts have most recently left them. Refreshed from the scene when it is set,
    /// then mutated in place each frame so the scene itself stays immutable.
    private var workingLayers: [RenderableLayer] = []

    public init(renderDevice: RenderDevice) throws {
        self.renderDevice = renderDevice
        self.quads = try QuadRenderer(device: renderDevice.device)
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
        device: any MTLDevice
    ) throws -> RenderableScene {
        let assets = SceneAssets(
            wallpaperID: wallpaperID, directory: directory, packageURL: packageURL
        )
        guard let sceneData = assets.data(for: "scene.json") else {
            throw SceneError.missingSceneDocument
        }
        let document = try JSONDecoder().decode(SceneDocument.self, from: sceneData)
        return SceneBuilder().build(document: document, assets: assets, device: device)
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
            quads.encode(
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
        scene: RenderableScene, cameraOffset: SIMD2<Float>, into draws: inout [QuadDraw]
    ) {
        draws.removeAll(keepingCapacity: true)
        for sceneLayer in workingLayers where sceneLayer.isVisible {
            draws.append(
                QuadDraw(
                    transform: sceneLayer.modelMatrix(cameraOffset: cameraOffset),
                    tint: sceneLayer.tint,
                    texture: sceneLayer.texture,
                    blend: sceneLayer.blend
                )
            )
        }
        for system in scene.particles {
            system.update(deltaTime: clock.delta)
            system.appendDraws(to: &draws, cameraOffset: cameraOffset)
        }
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

        func drawBatch(_ draws: [QuadDraw], into target: any MTLTexture, clearFirst: Bool) {
            guard !draws.isEmpty || clearFirst else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = clearFirst ? .clear : .load
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = clearFirst
                ? clear
                : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            quads.encode(
                draws, into: encoder, projection: projection, pixelFormat: target.pixelFormat
            )
            encoder.endEncoding()
        }

        var batch: [QuadDraw] = []

        for sceneLayer in workingLayers where sceneLayer.isVisible {
            let draw = QuadDraw(
                transform: sceneLayer.modelMatrix(cameraOffset: cameraOffset),
                tint: sceneLayer.tint,
                texture: sceneLayer.texture,
                blend: sceneLayer.blend
            )

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
                quads.encode(
                    [draw], into: encoder, projection: projection,
                    pixelFormat: isolated.texture.pixelFormat
                )
                encoder.endEncoding()
            }

            post.apply(
                sceneLayer.effects,
                source: isolated.texture,
                destination: processed.texture,
                commandBuffer: buffer,
                pool: pool
            )

            // Composite the processed layer back, full-frame.
            let composite = QuadDraw(
                transform: Self.fullscreenTransform(projection: projection),
                texture: processed.texture,
                blend: .premultipliedAlpha
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
        drawBatch(particleDraws, into: accumulator.texture, clearFirst: false)

        // Scene-wide chain straight into the drawable.
        post.apply(
            scene.sceneEffects,
            source: accumulator.texture,
            destination: drawable.texture,
            commandBuffer: buffer,
            pool: pool
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
            QuadDraw(
                transform: layer.modelMatrix(cameraOffset: cameraOffset),
                tint: layer.tint,
                texture: layer.texture,
                blend: layer.blend
            )
        }
        for system in scene.particles {
            system.appendDraws(to: &draws, cameraOffset: cameraOffset)
        }

        quads.encode(draws, into: encoder, projection: projection, pixelFormat: .bgra8Unorm)
        encoder.endEncoding()

        if hasEffects, intermediate != nil {
            // Per-layer chains are folded into the scene chain here. This path is a diagnostic,
            // and reproducing exact per-layer isolation would mean duplicating the whole live
            // composition path for no extra diagnostic value.
            let combined = scene.layers.flatMap(\.effects) + scene.sceneEffects
            post.apply(
                combined,
                source: compositionTarget,
                destination: target,
                commandBuffer: buffer,
                pool: pool
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
