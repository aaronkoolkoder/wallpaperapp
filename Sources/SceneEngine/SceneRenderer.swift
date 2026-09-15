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

    public init(renderDevice: RenderDevice) throws {
        self.renderDevice = renderDevice
        self.quads = try QuadRenderer(device: renderDevice.device)
        self.pool = FBOPool(device: renderDevice.device)
    }

    public func setScene(_ scene: RenderableScene) {
        self.scene = scene
        camera = scene.cameraMotion
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

        guard let buffer = renderDevice.makeFrameCommandBuffer(label: "scene"),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        // Aspect-fill the scene's ortho box into the drawable. Letterboxing a wallpaper would
        // show bars at the edges of the desktop, which is never what anyone wants.
        let projection = aspectFilledProjection(
            scene: scene,
            drawableSize: SIMD2(Float(drawable.texture.width), Float(drawable.texture.height))
        )

        let draws = scene.layers
            .filter(\.isVisible)
            .map { layer in
                QuadDraw(
                    transform: layer.modelMatrix(cameraOffset: cameraOffset),
                    tint: layer.tint,
                    texture: layer.texture,
                    blend: layer.blend
                )
            }

        quads.encode(draws, into: encoder, projection: projection, pixelFormat: layer.pixelFormat)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()

        pool.endFrame()
        framesRendered &+= 1
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
    public func renderOffscreen(
        width: Int, height: Int, pointer: SIMD2<Float> = .zero
    ) -> CGImage? {
        guard let scene else { return nil }

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

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
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
        let draws = scene.layers.filter(\.isVisible).map { layer in
            QuadDraw(
                transform: layer.modelMatrix(cameraOffset: cameraOffset),
                tint: layer.tint,
                texture: layer.texture,
                blend: layer.blend
            )
        }

        quads.encode(draws, into: encoder, projection: projection, pixelFormat: .bgra8Unorm)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

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
