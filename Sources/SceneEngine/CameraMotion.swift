import Foundation
import WEFormat
import simd

/// Drives the scene camera's parallax response to the pointer.
///
/// Parallax is the signature Wallpaper Engine effect and the thing that most obviously separates
/// a real scene from a video recording of one: layers at different declared depths slide past
/// each other as the pointer moves, giving the flat composition apparent depth.
///
/// The motion is smoothed rather than tracking the pointer exactly. Raw tracking reads as jittery
/// and cheap — Wallpaper Engine's own `cameraparallaxdelay` exists for the same reason — so the
/// offset eases toward its target with a frame-rate-independent exponential decay.
public struct CameraMotion: Sendable {
    /// How far the camera travels at full deflection, in scene units.
    public var amount: Float
    /// How strongly the pointer drives it. 0 disables pointer response entirely.
    public var mouseInfluence: Float
    /// Smoothing time constant in seconds. Larger is lazier.
    public var delay: Float
    public var isEnabled: Bool

    private var current: SIMD2<Float> = .zero
    private var target: SIMD2<Float> = .zero

    public init(
        amount: Float = 1.0,
        mouseInfluence: Float = 1.0,
        delay: Float = 0.2,
        isEnabled: Bool = true
    ) {
        self.amount = amount
        self.mouseInfluence = mouseInfluence
        self.delay = delay
        self.isEnabled = isEnabled
    }

    /// Build from a scene's declared settings.
    public init(general: SceneGeneral?) {
        self.init(
            amount: Float(general?.cameraParallaxAmount ?? 1.0),
            mouseInfluence: Float(general?.cameraParallaxMouseInfluence ?? 1.0),
            delay: Float(general?.cameraParallaxDelay ?? 0.2),
            isEnabled: general?.cameraParallax ?? true
        )
    }

    /// Feed a pointer position normalised to [-1, 1] with the origin at screen centre.
    public mutating func setPointer(normalized: SIMD2<Float>) {
        guard isEnabled else {
            target = .zero
            return
        }
        let clamped = simd_clamp(normalized, SIMD2(-1, -1), SIMD2(1, 1))
        target = clamped * amount * mouseInfluence
    }

    /// Advance the smoothing. `deltaTime` in seconds.
    ///
    /// The decay is expressed as `1 - exp(-dt / tau)` rather than a fixed per-frame lerp factor,
    /// so the motion feels identical at 24fps and 120fps. A plain lerp would make the camera
    /// visibly lazier on a slower display, and the frame rate here changes with battery state.
    public mutating func update(deltaTime: Float) {
        guard delay > 0.0001 else {
            current = target
            return
        }
        let alpha = 1 - exp(-max(0, deltaTime) / delay)
        current += (target - current) * alpha
    }

    /// Current camera offset in scene units.
    public var offset: SIMD2<Float> { current }

    /// Offset applied to a layer at a given declared depth.
    ///
    /// Depth runs 0 (pinned to the camera, moves most) to 1 (infinitely far, stationary), so the
    /// contribution is inverted. Getting this backwards makes the background slide across the
    /// foreground, which looks wrong immediately but is easy to write.
    public func offset(forDepth depth: SIMD2<Float>) -> SIMD2<Float> {
        current * depth
    }

    public mutating func reset() {
        current = .zero
        target = .zero
    }
}

/// Scene time, advanced once per frame.
///
/// Wallpaper Engine shaders and animations read elapsed time, so this is the clock everything
/// animated hangs off. Tracks its own delta rather than trusting the display link's cadence,
/// which changes whenever the power policy retargets the frame rate.
public struct SceneClock: Sendable {
    public private(set) var elapsed: Float = 0
    public private(set) var delta: Float = 0
    public private(set) var frameIndex: UInt64 = 0

    private var lastTimestamp: CFTimeInterval?

    public init() {}

    public mutating func advance(to timestamp: CFTimeInterval) {
        defer {
            lastTimestamp = timestamp
            frameIndex &+= 1
        }
        guard let last = lastTimestamp else {
            delta = 0
            return
        }
        // Clamp the step. A wallpaper resuming from occlusion or system sleep can see an
        // arbitrarily large gap, and letting that through makes every animation jump — or, for
        // anything integrating over dt, explode.
        delta = Float(min(max(0, timestamp - last), 0.1))
        elapsed += delta
    }

    public mutating func reset() {
        elapsed = 0
        delta = 0
        frameIndex = 0
        lastTimestamp = nil
    }

    /// Advance by an explicit step, for headless rendering where there is no display link to
    /// supply timestamps.
    public mutating func advanceForTesting(delta step: Float) {
        delta = max(0, step)
        elapsed += delta
        frameIndex &+= 1
    }
}
