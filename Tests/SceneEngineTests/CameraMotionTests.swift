import Testing
import simd
@testable import SceneEngine

@Suite("CameraMotion")
struct CameraMotionTests {

    @Test("Eases toward the pointer rather than snapping")
    func easesTowardTarget() {
        var camera = CameraMotion(amount: 100, mouseInfluence: 1, delay: 0.2)
        camera.setPointer(normalized: SIMD2(1, 0))

        camera.update(deltaTime: 1.0 / 60)
        let first = camera.offset.x
        // Raw tracking reads as jittery and cheap, which is why the delay exists.
        #expect(first > 0)
        #expect(first < 100)

        for _ in 0 ..< 200 { camera.update(deltaTime: 1.0 / 60) }
        #expect(abs(camera.offset.x - 100) < 0.5)
    }

    @Test("Smoothing is frame-rate independent")
    func frameRateIndependent() {
        // The power policy retargets the frame rate with battery state, so a per-frame lerp
        // would make the camera visibly lazier on battery. Both of these advance one second.
        var slow = CameraMotion(amount: 100, mouseInfluence: 1, delay: 0.25)
        var fast = CameraMotion(amount: 100, mouseInfluence: 1, delay: 0.25)
        slow.setPointer(normalized: SIMD2(1, 0))
        fast.setPointer(normalized: SIMD2(1, 0))

        for _ in 0 ..< 24 { slow.update(deltaTime: 1.0 / 24) }
        for _ in 0 ..< 120 { fast.update(deltaTime: 1.0 / 120) }

        #expect(abs(slow.offset.x - fast.offset.x) < 1.0)
    }

    @Test("A zero delay settles immediately")
    func zeroDelaySnaps() {
        var camera = CameraMotion(amount: 50, mouseInfluence: 1, delay: 0)
        camera.setPointer(normalized: SIMD2(1, 1))
        camera.update(deltaTime: 0)
        #expect(camera.offset == SIMD2(50, 50))
    }

    @Test("Disabled parallax never moves")
    func disabledStaysPut() {
        var camera = CameraMotion(amount: 100, mouseInfluence: 1, delay: 0, isEnabled: false)
        camera.setPointer(normalized: SIMD2(1, 1))
        camera.update(deltaTime: 1)
        #expect(camera.offset == .zero)
    }

    @Test("Pointer input is clamped to the unit range")
    func pointerClamped() {
        var camera = CameraMotion(amount: 10, mouseInfluence: 1, delay: 0)
        camera.setPointer(normalized: SIMD2(5, -5))
        camera.update(deltaTime: 0)
        // A pointer outside the screen must not fling the camera off into space.
        #expect(camera.offset == SIMD2(10, -10))
    }

    @Test("Layer displacement scales with declared depth")
    func depthScalesOffset() {
        var camera = CameraMotion(amount: 100, mouseInfluence: 1, delay: 0)
        camera.setPointer(normalized: SIMD2(1, 0))
        camera.update(deltaTime: 0)

        #expect(camera.offset(forDepth: SIMD2(0, 0)) == SIMD2(0, 0))
        #expect(camera.offset(forDepth: SIMD2(0.5, 0)).x == 50)
    }
}

@Suite("SceneClock")
struct SceneClockTests {

    @Test("The first frame reports no elapsed time")
    func firstFrameHasNoDelta() {
        var clock = SceneClock()
        clock.advance(to: 1000)
        #expect(clock.delta == 0)
        #expect(clock.elapsed == 0)
    }

    @Test("Accumulates elapsed time across frames")
    func accumulates() {
        var clock = SceneClock()
        clock.advance(to: 100.0)
        clock.advance(to: 100.05)
        clock.advance(to: 100.10)
        #expect(abs(clock.elapsed - 0.10) < 0.0001)
        #expect(clock.frameIndex == 3)
    }

    @Test("Clamps a large gap so resuming does not jump the animation")
    func clampsLargeGap() {
        var clock = SceneClock()
        clock.advance(to: 100)
        // A wallpaper resuming from occlusion or sleep can see an arbitrarily large gap.
        // Letting it through makes every animation jump, and explodes anything integrating dt.
        clock.advance(to: 500)
        #expect(clock.delta <= 0.1)
    }

    @Test("Never reports a negative delta")
    func neverNegative() {
        var clock = SceneClock()
        clock.advance(to: 100)
        clock.advance(to: 50)
        #expect(clock.delta >= 0)
    }
}

@Suite("Parallax safe margin")
struct ParallaxMarginTests {

    private func scene(depth: SIMD2<Float>, parallaxOn: Bool) -> RenderableScene {
        var layer = RenderableLayer(
            name: "l", origin: .zero, angles: .zero, scale: SIMD3(1, 1, 1),
            size: SIMD2(1920, 1080), tint: SIMD4(1, 1, 1, 1), blend: .premultipliedAlpha,
            texture: nil, parallaxDepth: depth, isVisible: true
        )
        layer.parallaxDepth = depth
        return RenderableScene(
            layers: [layer], orthoSize: SIMD2(1920, 1080),
            clearColor: SIMD4(0, 0, 0, 1),
            cameraMotion: CameraMotion(amount: 1, mouseInfluence: 1, delay: 0, isEnabled: parallaxOn),
            report: .init(wallpaperID: "t")
        )
    }

    @Test("Parallax widens the projection so deflection cannot uncover the edge")
    func marginZoomsIn() {
        let withParallax = scene(depth: SIMD2(100, 60), parallaxOn: true)
        #expect(withParallax.maximumParallaxShift == SIMD2(100, 60))

        // Zoomed in: half-width shrank, so the clip-space scale grew.
        let plain = scene(depth: .zero, parallaxOn: true)
        #expect(withParallax.projectionMatrix.columns.0.x > plain.projectionMatrix.columns.0.x)
    }

    @Test("No margin is taken when parallax is off")
    func noMarginWhenDisabled() {
        #expect(scene(depth: SIMD2(100, 60), parallaxOn: false).maximumParallaxShift == .zero)
    }

    @Test("A depth large enough to invert the box still yields a usable projection")
    func absurdDepthDoesNotInvert() {
        // Content can declare anything. A margin exceeding the half-extent must not produce a
        // negative or zero divisor and blow the matrix up.
        let matrix = scene(depth: SIMD2(99_999, 99_999), parallaxOn: true).projectionMatrix
        #expect(matrix.columns.0.x.isFinite && matrix.columns.0.x > 0)
        #expect(matrix.columns.1.y.isFinite && matrix.columns.1.y > 0)
    }
}
