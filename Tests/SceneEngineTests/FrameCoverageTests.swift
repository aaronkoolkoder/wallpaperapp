import Metal
import Testing
import simd
@testable import SceneEngine

/// The two reasons a scene reached the desktop looking wrong while every existing test passed.
///
/// Both were invisible to the offscreen harness because it asserted that a frame was *produced*,
/// never what was in it. A scene that renders a white rectangle renders just as many frames as
/// one that renders the wallpaper.
@Suite("Frame coverage")
struct FrameCoverageTests {

    private func scene(ortho: SIMD2<Float>) -> RenderableScene {
        RenderableScene(
            layers: [], orthoSize: ortho, clearColor: SIMD4(0.7, 0.7, 0.7, 1),
            cameraMotion: CameraMotion(amount: 0, mouseInfluence: 0, delay: 0, isEnabled: false),
            report: .init(wallpaperID: "t")
        )
    }

    /// Scene-space point through the projection, into normalised device coordinates.
    private func ndc(_ point: SIMD2<Float>, _ projection: simd_float4x4) -> SIMD2<Float> {
        let clip = projection * SIMD4(point.x, point.y, 0, 1)
        return SIMD2(clip.x / clip.w, clip.y / clip.w)
    }

    @Test("Aspect-fill covers the whole frame, centred, without distorting the scene",
          arguments: [
            SIMD2<Float>(1512, 982),    // narrower than 16:9 — the user's own display
            SIMD2<Float>(3440, 1440),   // ultrawide, which crops the other axis
            SIMD2<Float>(1920, 1080),   // exact match: must be left alone
          ])
    func aspectFillCoversTheFrame(drawable: SIMD2<Float>) {
        let scene = self.scene(ortho: SIMD2(1920, 1080))
        let projection = SceneRenderer.aspectFilledProjection(
            scene: scene, drawableSize: drawable
        )

        let low = ndc(SIMD2(0, 0), projection)
        let high = ndc(SIMD2(1920, 1080), projection)

        // Covered: the scene box reaches or overflows every edge of the frame. Falling short on
        // an axis is what left a band of the clear colour down one side of the desktop.
        #expect(low.x <= -1 + 1e-4 && high.x >= 1 - 1e-4, "scene does not span the frame in x")
        #expect(low.y <= -1 + 1e-4 && high.y >= 1 - 1e-4, "scene does not span the frame in y")

        // Centred: whatever is cropped is cropped evenly, not taken off one side.
        #expect(abs(low.x + high.x) < 1e-4, "horizontal crop is lopsided")
        #expect(abs(low.y + high.y) < 1e-4, "vertical crop is lopsided")

        // Undistorted: one scene unit must be the same number of pixels on both axes.
        let pixelsPerUnitX = (high.x - low.x) / 2 * (drawable.x / 2) / (scene.orthoSize.x / 2)
        let pixelsPerUnitY = (high.y - low.y) / 2 * (drawable.y / 2) / (scene.orthoSize.y / 2)
        #expect(abs(pixelsPerUnitX - pixelsPerUnitY) < 1e-3, "the scene is stretched")
    }

    @Test("A processed layer is composited back over exactly the frame",
          arguments: [SIMD2<Float>(1512, 982), SIMD2<Float>(3440, 1440), SIMD2<Float>(1920, 1080)])
    func compositeQuadCoversTheFrame(drawable: SIMD2<Float>) {
        // The quad a layer's effect output is drawn back with. Built from the projection's
        // scale alone it assumed a projection centred on zero, but the scene's places its
        // corner at the origin — and the quad landed a half-frame down and left, showing each
        // effected layer's top-right quarter in the bottom-left quarter of the desktop.
        let projection = SceneRenderer.aspectFilledProjection(
            scene: scene(ortho: SIMD2(1920, 1080)), drawableSize: drawable
        )
        let quad = projection * SceneRenderer.fullscreenTransform(projection: projection)

        for corner in [SIMD2<Float>(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(-0.5, 0.5), SIMD2(0.5, 0.5)] {
            let clip = quad * SIMD4(corner.x, corner.y, 0, 1)
            let expected = corner * 2
            #expect(abs(clip.x / clip.w - expected.x) < 1e-4 && abs(clip.y / clip.w - expected.y) < 1e-4,
                    "corner \(corner) lands at (\(clip.x / clip.w), \(clip.y / clip.w)), not \(expected)")
        }
    }

    @Test("A texture slot with nothing bound still reports a usable resolution")
    func missingResolutionIsNeverZero() {
        // `foliagesway.vert` computes `g_Texture0Resolution.z / .w` and feeds the result into
        // every UV its fragment stage samples with. A zero resolution makes that 0/0, and one
        // NaN UV turns the entire pass white — which is what a scene "staying a static image"
        // on the desktop actually looked like.
        let resolutions = MaterialRenderer.textureResolutions(
            declared: ["g_Texture0", "g_Texture1", "g_Texture2"], textures: [:]
        )

        #expect(resolutions.count == 3, "a declared slot must have an entry to index")
        for (slot, resolution) in resolutions.enumerated() {
            #expect(resolution.min() > 0, "slot \(slot) reports a zero component")
            #expect((resolution.z / resolution.w).isFinite, "slot \(slot) makes an aspect NaN")
            #expect((resolution.z / resolution.x).isFinite, "slot \(slot) makes a UV rescale NaN")
        }
    }

    @Test("A bound texture reports its own size in both halves")
    func boundResolutionIsTheTextureSize() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false
        )
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))

        let resolutions = MaterialRenderer.textureResolutions(
            declared: ["g_Texture0", "g_Texture1"], textures: ["g_Texture0": texture]
        )

        // xy is the allocation and zw the image within it; with no padding they agree.
        #expect(resolutions[0] == SIMD4(1920, 1080, 1920, 1080))
        #expect(abs(resolutions[0].z / resolutions[0].w - Float(1920) / Float(1080)) < 1e-6)
        #expect(resolutions[1] == SIMD4(1, 1, 1, 1))
    }

    @Test("A layer whose texture was padded draws only the image, not the margin")
    func paddedLayerStopsAtTheImage() {
        // A 2372x1334 painting is stored in a 4096x2048 allocation with the image in the
        // top-left corner. Drawing the full 0..1 puts the picture in the corner of the desktop
        // with the clear colour filling the rest — which is what it did.
        var layer = RenderableLayer(
            name: "cabin", origin: SIMD3(1186, 667, 0), angles: .zero, scale: SIMD3(1, 1, 1),
            size: SIMD2(2372, 1334), tint: SIMD4(1, 1, 1, 1), blend: .premultipliedAlpha,
            texture: nil, parallaxDepth: .zero, isVisible: true
        )
        layer.uvScale = SIMD2(2372.0 / 4096.0, 1334.0 / 2048.0)

        let draw = SceneRenderer.sceneDraw(for: layer, cameraOffset: .zero)
        #expect(draw.quad.uvRect.x == 0 && draw.quad.uvRect.y == 0)
        #expect(abs(draw.quad.uvRect.z - layer.uvScale.x) < 1e-6, "samples past the image in u")
        #expect(abs(draw.quad.uvRect.w - layer.uvScale.y) < 1e-6, "samples past the image in v")
    }

    @Test("A padded texture describes both of its sizes")
    func paddedTextureReportsBothSizes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 4096, height: 2048, mipmapped: false
        )
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let loaded = SceneTexture(texture: texture, imageSize: SIMD2(2372, 1334))

        // Allocation in xy, image in zw — the order `foliagesway.vert` reads them in.
        #expect(loaded.resolution == SIMD4(4096, 2048, 2372, 1334))
        #expect(abs(loaded.uvScale.x - 2372.0 / 4096.0) < 1e-6)

        let resolutions = MaterialRenderer.textureResolutions(
            declared: ["g_Texture0"], textures: ["g_Texture0": texture],
            sizes: ["g_Texture0": loaded.resolution]
        )
        #expect(resolutions[0] == SIMD4(4096, 2048, 2372, 1334),
                "a measured size must win over the allocation")
    }

    @Test("Slots are indexed by the digit in the name, not by declaration order")
    func slotsFollowTheName() {
        // SPIRV-Cross drops samplers a combo leaves unused and renumbers the rest, so
        // declaration order and slot number part company as soon as a shader has combos.
        let resolutions = MaterialRenderer.textureResolutions(
            declared: ["g_Texture3", "g_Texture0"], textures: [:]
        )
        #expect(resolutions.count == 4, "g_Texture3 must be reachable at index 3")
    }
}
