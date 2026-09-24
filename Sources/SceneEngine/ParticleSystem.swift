import Diagnostics
import Foundation
import Metal
import MetalRenderer
import WEFormat
import simd

/// One live particle. A plain struct in a pre-allocated array rather than a class: this is
/// touched for every particle every frame, and reference counting a few thousand objects per
/// frame would dominate the simulation cost.
struct Particle {
    var position: SIMD3<Float> = .zero
    var velocity: SIMD3<Float> = .zero
    var size: Float = 1
    var sizeInitial: Float = 1
    var rotation: Float = 0
    var angularVelocity: Float = 0
    var color: SIMD3<Float> = .one
    var colorInitial: SIMD3<Float> = .one
    var alpha: Float = 1
    var alphaInitial: Float = 1
    var age: Float = 0
    var lifetime: Float = 1
    var isAlive: Bool = false
}

/// Simulates and draws one particle emitter.
///
/// Implements the behaviours that cover the common case, and reports the rest through the
/// compatibility system rather than silently ignoring them — a scene whose snow does not fall
/// should say so.
public final class ParticleSystem {
    private var particles: [Particle]
    private let document: ParticleDocument
    private var emissionAccumulator: Float = 0
    private var random = SystemRandomNumberGenerator()

    /// Placement of the emitter in scene space, from the owning object.
    public var origin: SIMD3<Float> = .zero
    public var texture: (any MTLTexture)?
    /// Frames of an animated sprite. Each particle plays them from its own birth, so a flock
    /// flaps out of step rather than in unison.
    public var sprite: SpriteAnimation?
    public var blend: BlendMode = .premultipliedAlpha
    public private(set) var findings: [CompatibilityFinding] = []

    // Cached emitter/initializer/operator parameters, resolved once at load rather than looked
    // up by string every frame.
    private var emissionRate: Float = 0
    /// Spawn distance from the emitter, per axis. See `configure()`.
    private var emitterExtent: SIMD3<Float> = .zero
    private var emitterInnerExtent: SIMD3<Float> = .zero
    /// Axis mask: `"1 1 0"` keeps a 2D scene's particles on its plane.
    private var emitterDirections: SIMD3<Float> = .one
    /// The emitter's own offset from the object's origin.
    private var emitterOffset: SIMD3<Float> = .zero
    private var emitterIsSphere = false
    /// Turbulence: a smooth, time-varying push. Approximated, not Wallpaper Engine's noise.
    private var turbulenceScale: Float = 0
    private var turbulenceSpeed: Float = 0
    /// A launch velocity drawn from a noise field, per `turbulentvelocityrandom`.
    private var hasTurbulentVelocity = false
    private var turbulentSpeedRange: (Float, Float) = (0, 0)
    private var turbulentVelocityScale: Float = 0.005
    private var turbulentVelocityOffset: Float = 0
    private var turbulenceTimescale: Float = 0
    private var elapsed: Float = 0
    private var lifetimeRange: ClosedRange<Float> = 1...1
    private var sizeRange: ClosedRange<Float> = 10...10
    private var alphaRange: ClosedRange<Float> = 1...1
    private var velocityMin: SIMD3<Float> = .zero
    private var velocityMax: SIMD3<Float> = .zero
    private var colorMin: SIMD3<Float> = .one
    private var colorMax: SIMD3<Float> = .one
    private var angularVelocityRange: ClosedRange<Float> = 0...0
    private var rotationRange: ClosedRange<Float> = 0...0

    private var gravity: SIMD3<Float> = .zero
    private var drag: Float = 0
    private var fadeInTime: Float = 0
    private var fadeOutTime: Float = 0
    private var hasAlphaFade = false
    private var sizeChangeScale: Float = 1
    private var hasSizeChange = false
    /// Colour over life, as a multiplier on the particle's own colour.
    private var hasColorChange = false
    private var colorChangeSpan: ClosedRange<Float> = 0...1
    private var colorChangeFrom: SIMD3<Float> = .one
    private var colorChangeTo: SIMD3<Float> = .one

    /// The instance's own tuning of the preset: fewer, dimmer, larger, slower.
    public let overrides: ParticleOverrides

    public init(document: ParticleDocument, overrides: ParticleOverrides = .none) {
        self.document = document
        self.overrides = overrides
        // `count` scales how many may be alive at once, so it has to be settled before the
        // storage is allocated — and clamped for the same reason the document's own count is.
        let scaled = Float(document.maxCount) * (overrides.count ?? 1)
        particles = [Particle](
            repeating: Particle(), count: min(max(0, Int(scaled.rounded())), 20_000)
        )
        configure()
    }

    public var maxCount: Int { particles.count }

    /// Whether this system places its own particles, rather than being carried by another's.
    ///
    /// A child system in Wallpaper Engine can be attached to each of its parent's particles —
    /// the trail behind a spark, the glow under a shooting star. Those either emit nothing of
    /// their own or emit from a single point, because the parent supplies the position. One
    /// that emits across a volume is a second layer of the same effect in the same place, and
    /// stands on its own: the second kind of leaf in a drift, the embers over a fire.
    public var placesItsOwnParticles: Bool {
        emissionRate > 0 && emitterExtent.max() >= 16
    }
    public var liveCount: Int { particles.lazy.filter(\.isAlive).count }
    public var materialPath: String? { document.material }
    /// Systems this one carries with it, by path.
    public var children: [String] { document.children }

    // MARK: - Configuration

    private func configure() {
        for emitter in document.emitters {
            switch emitter.name {
            case "boxrandom", "sphererandom":
                emitterIsSphere = emitter.name == "sphererandom"
                emissionRate += emitter.float("rate") ?? 10
                // Wallpaper Engine leaves a value out of the file when it equals the default,
                // and the default spawn distance is 256. Reading a missing `distancemax` as zero
                // spawned every particle on one point: in a real library, 15,000 a second of them
                // piled into a white square in the middle of a face.
                let outer = vector(emitter, "distancemax", default: SIMD3(repeating: 256))
                let inner = vector(emitter, "distancemin", default: .zero)
                emitterExtent = simd_max(outer, inner)
                emitterInnerExtent = simd_min(outer, inner)
                emitterDirections = vector(emitter, "directions", default: .one)
                emitterOffset = vector(emitter, "origin", default: .zero)
            default:
                note(.degraded, "Particle emitter", "\(emitter.name) is not supported")
            }
        }
        if document.emitters.isEmpty { emissionRate = 0 }

        for initializer in document.initializers {
            switch initializer.name {
            case "lifetimerandom":
                lifetimeRange = range(initializer, default: 1...1)
            case "sizerandom":
                sizeRange = range(initializer, default: 10...10)
            case "alpharandom":
                alphaRange = range(initializer, default: 1...1)
            case "velocityrandom":
                let (low, high) = bounds(initializer, fallback: .zero)
                velocityMin = low
                velocityMax = high
            case "colorrandom":
                // Colours are authored 0-255 here, unlike everywhere else in the format.
                let (low, high) = bounds(initializer, fallback: SIMD3(repeating: 255))
                colorMin = low / 255
                colorMax = high / 255
            case "angularvelocityrandom":
                angularVelocityRange = range(initializer, default: 0...0)
            case "rotationrandom":
                rotationRange = range(initializer, default: 0...0)
            case "turbulentvelocityrandom":
                // A launch velocity taken from a noise field, on top of whatever the particle
                // was already given. It used to read `min` and `max`, which this node does not
                // have — it carries `speedmin` and `speedmax` — so every particle came out of
                // it with a velocity of exactly zero, and the velocity a `velocityrandom`
                // beside it had just set was overwritten with that zero. An autumn wallpaper's
                // leaves hung motionless above the top of the frame and never fell into it.
                hasTurbulentVelocity = true
                turbulentSpeedRange = (
                    initializer.float("speedmin") ?? 0, initializer.float("speedmax") ?? 0
                )
                turbulentVelocityScale = initializer.float("scale") ?? 0.005
                turbulentVelocityOffset = initializer.float("offset") ?? 0
                note(
                    .degraded, "Particle motion",
                    "turbulent velocity is approximated with a noise field"
                )
            default:
                note(.degraded, "Particle initializer", "\(initializer.name) is not supported")
            }
        }

        for op in document.operators {
            switch op.name {
            case "movement":
                if let g = op.vector("gravity") {
                    gravity = SIMD3(Float(g.x), Float(g.y), Float(g.z))
                }
                drag = op.float("drag") ?? 0
            case "alphafade":
                hasAlphaFade = true
                fadeInTime = op.float("fadeintime") ?? 0.1
                fadeOutTime = op.float("fadeouttime") ?? 0.3
            case "sizechange":
                hasSizeChange = true
                sizeChangeScale = op.float("scale") ?? 1
            case "angularmovement":
                // Already integrated from angular velocity; nothing extra to configure.
                break
            case "colorchange":
                hasColorChange = true
                let start = op.float("starttime") ?? 0
                let end = op.float("endtime") ?? 1
                colorChangeSpan = min(start, end)...max(start, end)
                colorChangeFrom = vector(op, "startvalue", default: .one)
                colorChangeTo = vector(op, "endvalue", default: .one)
            case "turbulence":
                turbulenceScale = op.float("scale") ?? 0.005
                let slowest = op.float("speedmin") ?? 500
                let fastest = op.float("speedmax") ?? 1000
                turbulenceSpeed = (slowest + fastest) / 2
                turbulenceTimescale = op.float("timescale") ?? 1
                note(.degraded, "Particle operator", "turbulence is approximated")
            default:
                note(.degraded, "Particle operator", "\(op.name) is not supported")
            }
        }

        applyOverrides()
    }

    /// Folds the instance's own tuning into what the preset asked for.
    ///
    /// Applied once here rather than per particle: every one of these is a scale on a value
    /// that is read at spawn, so scaling the ranges gives the same result as scaling each
    /// particle and costs nothing on the frame path.
    private func applyOverrides() {
        if let rate = overrides.rate { emissionRate *= rate }
        if let lifetime = overrides.lifetime, lifetime > 0 {
            lifetimeRange = scaled(lifetimeRange, by: lifetime)
        }
        if let size = overrides.size { sizeRange = scaled(sizeRange, by: size) }
        if let alpha = overrides.alpha { alphaRange = scaled(alphaRange, by: alpha) }
        if let speed = overrides.speed {
            velocityMin *= speed
            velocityMax *= speed
        }
        // The colour is a replacement, not a scale: the instance says what colour these are.
        if let colour = overrides.color {
            colorMin = colour
            colorMax = colour
        }
    }

    private func scaled(_ range: ClosedRange<Float>, by factor: Float) -> ClosedRange<Float> {
        let low = range.lowerBound * factor, high = range.upperBound * factor
        return low <= high ? low...high : high...low
    }

    private func range(_ node: ParticleNode, default fallback: ClosedRange<Float>) -> ClosedRange<Float> {
        let low = node.float("min") ?? fallback.lowerBound
        let high = node.float("max") ?? fallback.upperBound
        // Content sometimes writes min > max; swapping is friendlier than trapping on an
        // invalid ClosedRange, which would take the whole wallpaper down.
        return low <= high ? low...high : high...low
    }

    /// A node's `min` and `max` as a pair, with one standing in for a missing other.
    ///
    /// The format leaves out the bound that equals the other one, so `{"min": "255 255 255"}`
    /// means exactly white rather than anything between white and black. Reading the absent
    /// `max` as zero made every such value a random one: an autumn wallpaper's leaves, all
    /// declared white, fell in pink, green and grey.
    private func bounds(
        _ node: ParticleNode, fallback: SIMD3<Float>
    ) -> (SIMD3<Float>, SIMD3<Float>) {
        let low = node.vector("min").map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) }
        let high = node.vector("max").map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) }
        return (low ?? high ?? fallback, high ?? low ?? fallback)
    }

    private func vector(_ node: ParticleNode, _ key: String, default fallback: SIMD3<Float> = .zero) -> SIMD3<Float> {
        guard let v = node.vector(key) else { return fallback }
        return SIMD3(Float(v.x), Float(v.y), Float(v.z))
    }

    private func note(_ level: CompatibilityLevel, _ feature: String, _ detail: String) {
        let finding = CompatibilityFinding(level: level, feature: feature, detail: detail)
        guard !findings.contains(finding) else { return }
        findings.append(finding)
    }

    // MARK: - Simulation

    public func update(deltaTime: Float) {
        guard deltaTime > 0, !particles.isEmpty else { return }
        elapsed += deltaTime

        // Exponential rather than linear so a large drag cannot reverse the velocity, which a
        // naive `v -= v * drag * dt` does as soon as drag * dt exceeds 1. The same for every
        // particle, so worked out once.
        let dragFactor = drag > 0 ? exp(-drag * deltaTime) : 1
        let gravityStep = gravity * deltaTime
        let turbulenceStep = turbulenceSpeed * deltaTime

        // Age and integrate, through one buffer pointer: indexing the array property directly
        // pays a runtime exclusivity check on every read and write, which on a busy emitter was
        // a sizeable share of the frame.
        particles.withUnsafeMutableBufferPointer { buffer in
            for index in buffer.indices where buffer[index].isAlive {
                var particle = buffer[index]
                particle.age += deltaTime
                if particle.age >= particle.lifetime {
                    particle.isAlive = false
                    buffer[index] = particle
                    continue
                }

                particle.velocity += gravityStep
                particle.velocity *= dragFactor
                particle.position += particle.velocity * deltaTime
                if turbulenceStep > 0 {
                    // A speed the particle is carried at along the field, not a push its drag
                    // then soaks up. As a push, a 500-1000px/s emitter with drag 4 crawled at a
                    // quarter of that and 20,000 particles piled into one white blob.
                    particle.position += turbulence(at: particle.position) * turbulenceStep
                }
                particle.rotation += particle.angularVelocity * deltaTime

                if hasAlphaFade {
                    particle.alpha = particle.alphaInitial
                        * fadeFactor(age: particle.age, lifetime: particle.lifetime)
                }
                if hasSizeChange || hasColorChange {
                    let life = particle.age / max(0.0001, particle.lifetime)
                    if hasSizeChange {
                        particle.size = particle.sizeInitial * (1 + (sizeChangeScale - 1) * life)
                    }
                    if hasColorChange {
                        let span = max(0.0001, colorChangeSpan.upperBound - colorChangeSpan.lowerBound)
                        let t = min(max((life - colorChangeSpan.lowerBound) / span, 0), 1)
                        particle.color = particle.colorInitial
                            * (colorChangeFrom + (colorChangeTo - colorChangeFrom) * t)
                    }
                }

                buffer[index] = particle
            }
        }

        emit(deltaTime: deltaTime)
    }

    /// A smooth, swirling unit-ish field over position and time: a few crossed sine waves.
    /// Cheap enough for thousands of particles a frame, and it spreads and stirs them the way the
    /// operator is used for, which is what matters more than matching its exact noise.
    private func turbulence(at position: SIMD3<Float>) -> SIMD3<Float> {
        // `scale` is the field's frequency: one swirl every 1/scale units. Neighbours a fraction
        // of that apart are carried different ways, which is what scatters an emitter's output
        // across the scene instead of drifting it as one.
        let p = position * (turbulenceScale * 2 * .pi)
        let t = elapsed * turbulenceTimescale * 0.1
        return SIMD3(
            sinf(p.y * 1.7 + t) + sinf(p.z * 2.3 - t * 1.3),
            sinf(p.z * 1.9 - t * 0.7) + sinf(p.x * 2.1 + t),
            0
        ) * 0.5
    }

    private func fadeFactor(age: Float, lifetime: Float) -> Float {
        var factor: Float = 1
        if fadeInTime > 0, age < fadeInTime {
            factor *= age / fadeInTime
        }
        let remaining = lifetime - age
        if fadeOutTime > 0, remaining < fadeOutTime {
            factor *= max(0, remaining / fadeOutTime)
        }
        return factor
    }

    private func emit(deltaTime: Float) {
        guard emissionRate > 0 else { return }
        emissionAccumulator += emissionRate * deltaTime
        // Bound the burst. Resuming after a pause could otherwise try to spawn thousands at once.
        let spawnCount = min(Int(emissionAccumulator), particles.count)
        guard spawnCount > 0 else { return }
        emissionAccumulator -= Float(spawnCount)

        var spawned = 0
        for index in particles.indices where !particles[index].isAlive {
            particles[index] = makeParticle()
            spawned += 1
            if spawned >= spawnCount { break }
        }
    }

    private func makeParticle() -> Particle {
        var particle = Particle()
        particle.isAlive = true
        particle.age = 0
        particle.lifetime = max(0.01, Float.random(in: lifetimeRange, using: &random))

        var offset = SIMD3<Float>(
            .random(in: -1...1, using: &random),
            .random(in: -1...1, using: &random),
            .random(in: -1...1, using: &random)
        ) * emitterDirections
        if emitterIsSphere {
            // A direction, then a distance between the inner and outer radius: a sphere with a
            // minimum distance is a shell, and in a 2D scene a ring.
            let length = simd_length(offset)
            offset = length > 0.0001 ? offset / length : SIMD3(1, 0, 0) * emitterDirections
            let reach = Float.random(in: 0...1, using: &random)
            offset *= emitterInnerExtent + (emitterExtent - emitterInnerExtent) * reach
        } else {
            // Each axis between the inner and outer half-width, on either side.
            let magnitude = simd_abs(offset)
            let sign = simd_sign(offset)
            offset = sign * (emitterInnerExtent + (emitterExtent - emitterInnerExtent) * magnitude)
        }
        particle.position = origin + emitterOffset + offset

        particle.velocity = SIMD3(
            .random(in: componentRange(velocityMin.x, velocityMax.x), using: &random),
            .random(in: componentRange(velocityMin.y, velocityMax.y), using: &random),
            .random(in: componentRange(velocityMin.z, velocityMax.z), using: &random)
        )
        if hasTurbulentVelocity {
            // Sampled from the field rather than drawn at random, so particles spawned near
            // each other set off together — which is what makes it read as a draught rather
            // than as scatter.
            let sample = SIMD3(
                particle.position.x * turbulentVelocityScale + turbulentVelocityOffset,
                particle.position.y * turbulentVelocityScale + turbulentVelocityOffset,
                particle.position.z * turbulentVelocityScale
            )
            let direction = SIMD3(sinf(sample.y * 2.7), sinf(sample.x * 2.3 + 1.1), 0)
            let length = simd_length(direction)
            let speed = Float.random(
                in: componentRange(turbulentSpeedRange.0, turbulentSpeedRange.1), using: &random
            )
            if length > 0.0001 { particle.velocity += direction / length * speed }
        }
        particle.size = Float.random(in: sizeRange, using: &random)
        particle.sizeInitial = particle.size
        particle.alpha = Float.random(in: alphaRange, using: &random)
        particle.alphaInitial = particle.alpha
        particle.rotation = Float.random(in: rotationRange, using: &random) * .pi / 180
        particle.angularVelocity = Float.random(in: angularVelocityRange, using: &random) * .pi / 180
        particle.color = SIMD3(
            .random(in: componentRange(colorMin.x, colorMax.x), using: &random),
            .random(in: componentRange(colorMin.y, colorMax.y), using: &random),
            .random(in: componentRange(colorMin.z, colorMax.z), using: &random)
        )
        particle.colorInitial = particle.color
        if hasColorChange { particle.color *= colorChangeFrom }
        return particle
    }

    private func componentRange(_ low: Float, _ high: Float) -> ClosedRange<Float> {
        low <= high ? low...high : high...low
    }

    // MARK: - Drawing

    /// Whether the whole system draws from one texture, and so through `appendInstances`. A
    /// sprite sheet spread over several pages needs one per particle, and uses `appendDraws`.
    public var drawsAsInstances: Bool { (sprite?.pages.count ?? 1) <= 1 }

    /// The texture `appendInstances` draws with.
    public var instanceTexture: (any MTLTexture)? { sprite?.pages.first ?? texture }

    /// The box the live particles occupy in scene space, or nil when none are alive.
    ///
    /// For answering where an emitter's output actually went. A system can be at its full
    /// count and contribute nothing to the frame, because everything it made is off-screen.
    public var liveBounds: (minimum: SIMD2<Float>, maximum: SIMD2<Float>)? {
        var minimum = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        for particle in particles where particle.isAlive {
            let position = SIMD2(particle.position.x, particle.position.y)
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
            found = true
        }
        return found ? (minimum, maximum) : nil
    }

    /// Every live particle, as the GPU draws it.
    public func appendInstances(to instances: inout [ParticleInstance], cameraOffset: SIMD2<Float>) {
        let sprite = self.sprite
        particles.withUnsafeBufferPointer { buffer in
            for particle in buffer where particle.isAlive {
                instances.append(
                    ParticleInstance(
                        placement: SIMD4(
                            particle.position.x + cameraOffset.x,
                            particle.position.y + cameraOffset.y,
                            particle.size,
                            particle.rotation
                        ),
                        uvRect: sprite?.frame(at: particle.age).uvRect ?? SIMD4(0, 0, 1, 1),
                        tint: SIMD4(particle.color, particle.alpha)
                    )
                )
            }
        }
    }

    /// Append draws for every live particle.
    ///
    /// Writes into a caller-owned array rather than returning a new one, so a busy emitter does
    /// not allocate thousands of elements every frame on the render path.
    public func appendDraws(to draws: inout [QuadDraw], cameraOffset: SIMD2<Float>) {
        for particle in particles where particle.isAlive {
            let c = cosf(particle.rotation), s = sinf(particle.rotation)
            let matrix = simd_float4x4(
                SIMD4(c * particle.size, s * particle.size, 0, 0),
                SIMD4(-s * particle.size, c * particle.size, 0, 0),
                SIMD4(0, 0, 1, 0),
                SIMD4(
                    particle.position.x + cameraOffset.x,
                    particle.position.y + cameraOffset.y,
                    particle.position.z,
                    1
                )
            )
            let frame = sprite?.frame(at: particle.age)
            draws.append(
                QuadDraw(
                    transform: matrix,
                    uvRect: frame?.uvRect ?? SIMD4(0, 0, 1, 1),
                    tint: SIMD4(
                        particle.color.x, particle.color.y, particle.color.z, particle.alpha
                    ),
                    texture: frame.flatMap { sprite?.texture(for: $0) } ?? texture,
                    blend: blend
                )
            )
        }
    }
}
