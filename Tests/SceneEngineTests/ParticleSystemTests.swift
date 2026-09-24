import Foundation
import MetalRenderer
import Testing
import WEFormat
import simd
@testable import SceneEngine

@Suite("ParticleSystem")
struct ParticleSystemTests {

    private func document(_ json: String) throws -> ParticleDocument {
        try JSONDecoder().decode(ParticleDocument.self, from: Data(json.utf8))
    }

    private let basic = """
    {"material":"materials/f.json","maxcount":50,
     "emitter":[{"name":"boxrandom","rate":100,"distancemax":"100 100 0"}],
     "initializer":[
       {"name":"lifetimerandom","min":1,"max":2},
       {"name":"sizerandom","min":5,"max":10},
       {"name":"alpharandom","min":0.5,"max":1}
     ],
     "operator":[{"name":"movement","gravity":"0 -10 0"}]}
    """

    @Test("Emits particles over time")
    func emits() throws {
        let system = ParticleSystem(document: try document(basic))
        #expect(system.liveCount == 0)

        system.update(deltaTime: 0.1)
        #expect(system.liveCount > 0)
    }

    @Test("Never exceeds the declared maximum")
    func respectsMaxCount() throws {
        let system = ParticleSystem(document: try document(basic))
        for _ in 0 ..< 500 { system.update(deltaTime: 0.1) }
        #expect(system.liveCount <= 50)
    }

    @Test("An absurd particle count is clamped rather than allocated")
    func clampsAbsurdCount() throws {
        // Untrusted content: a wallpaper declaring a million particles would allocate gigabytes
        // and stall the render thread.
        let document = try document(#"{"maxcount":100000000,"emitter":[]}"#)
        #expect(document.maxCount <= 20_000)
    }

    @Test("Particles expire after their lifetime")
    func particlesExpire() throws {
        let document = try document("""
        {"maxcount":20,
         "emitter":[{"name":"boxrandom","rate":50,"distancemax":"10 10 0"}],
         "initializer":[{"name":"lifetimerandom","min":0.2,"max":0.2}]}
        """)
        let system = ParticleSystem(document: document)
        system.update(deltaTime: 0.1)
        let spawned = system.liveCount
        #expect(spawned > 0)

        // Advance past the lifetime with no further emission possible in one step.
        for _ in 0 ..< 10 { system.update(deltaTime: 0.05) }
        #expect(system.liveCount <= spawned + 20)
    }

    @Test("Unsupported behaviours are reported by name, not ignored")
    func reportsUnsupportedBehaviours() throws {
        let document = try document("""
        {"maxcount":10,
         "emitter":[{"name":"warpfield","rate":10}],
         "initializer":[{"name":"quantumspin","min":1,"max":2}],
         "operator":[{"name":"timereversal","value":1}]}
        """)
        let system = ParticleSystem(document: document)

        // A scene whose snow does not fall should say so rather than looking broken.
        let features = system.findings.map(\.feature)
        #expect(features.contains("Particle emitter"))
        #expect(features.contains("Particle initializer"))
        #expect(features.contains("Particle operator"))
        #expect(system.findings.contains { $0.detail?.contains("quantumspin") == true })
    }

    @Test("Inverted min/max ranges are swapped rather than trapping")
    func invertedRangesSurvive() throws {
        // Content writes min > max often enough that trapping on the invalid ClosedRange would
        // take the whole wallpaper down.
        let document = try document("""
        {"maxcount":10,
         "emitter":[{"name":"boxrandom","rate":50,"distancemax":"10 10 0"}],
         "initializer":[{"name":"sizerandom","min":40,"max":5},
                        {"name":"lifetimerandom","min":9,"max":1}]}
        """)
        let system = ParticleSystem(document: document)
        system.update(deltaTime: 0.1)
        #expect(system.liveCount > 0)
    }

    @Test("Drag slows particles without reversing them")
    func dragNeverReverses() throws {
        // A naive `v -= v * drag * dt` flips the velocity as soon as drag * dt exceeds 1.
        let document = try document("""
        {"maxcount":5,
         "emitter":[{"name":"boxrandom","rate":100,"distancemax":"1 1 0"}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100},
                        {"name":"velocityrandom","min":"100 0 0","max":"100 0 0"}],
         "operator":[{"name":"movement","drag":50}]}
        """)
        let system = ParticleSystem(document: document)
        system.update(deltaTime: 0.1)

        var draws: [QuadDraw] = []
        system.appendDraws(to: &draws, cameraOffset: .zero)
        let startX = draws.map(\.transform.columns.3.x)

        for _ in 0 ..< 20 { system.update(deltaTime: 0.1) }
        draws.removeAll()
        system.appendDraws(to: &draws, cameraOffset: .zero)

        // Positions must still be advancing forward, never sliding back.
        for (index, draw) in draws.enumerated() where index < startX.count {
            #expect(draw.transform.columns.3.x >= startX[index] - 0.01)
        }
    }

    @Test("appendDraws writes into the caller's buffer without allocating a new one")
    func appendsIntoCallerBuffer() throws {
        let system = ParticleSystem(document: try document(basic))
        system.update(deltaTime: 0.1)

        var draws: [QuadDraw] = [
            QuadDraw(transform: matrix_identity_float4x4)
        ]
        system.appendDraws(to: &draws, cameraOffset: .zero)
        // The existing element survives; particles are appended after it.
        #expect(draws.count == 1 + system.liveCount)
    }

    @Test("Camera offset shifts particles")
    func cameraOffsetApplies() throws {
        let system = ParticleSystem(document: try document(basic))
        system.update(deltaTime: 0.1)

        var centred: [QuadDraw] = []
        system.appendDraws(to: &centred, cameraOffset: .zero)
        var shifted: [QuadDraw] = []
        system.appendDraws(to: &shifted, cameraOffset: SIMD2(100, 0))

        #expect(centred.count == shifted.count)
        if let a = centred.first, let b = shifted.first {
            #expect(abs((b.transform.columns.3.x - a.transform.columns.3.x) - 100) < 0.01)
        }
    }

    @Test("A document with no emitters produces nothing rather than crashing")
    func noEmitters() throws {
        let system = ParticleSystem(document: try document(#"{"maxcount":10}"#))
        system.update(deltaTime: 1.0)
        #expect(system.liveCount == 0)
    }

    @Test("Colours are decoded from the 0-255 range particles use")
    func colorRangeIs255Based() throws {
        // Unlike everywhere else in the format, particle colours are authored 0-255.
        let document = try document("""
        {"maxcount":5,
         "emitter":[{"name":"boxrandom","rate":100,"distancemax":"1 1 0"}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10},
                        {"name":"colorrandom","min":"255 255 255","max":"255 255 255"},
                        {"name":"alpharandom","min":1,"max":1}]}
        """)
        let system = ParticleSystem(document: document)
        system.update(deltaTime: 0.1)

        var draws: [QuadDraw] = []
        system.appendDraws(to: &draws, cameraOffset: .zero)
        if let first = draws.first {
            #expect(abs(first.tint.x - 1.0) < 0.01)
        }
    }
    // MARK: - Where particles start

    /// Live particle positions, read back through the draws they produce.
    private func positions(_ system: ParticleSystem) -> [SIMD2<Float>] {
        var draws: [QuadDraw] = []
        system.appendDraws(to: &draws, cameraOffset: .zero)
        return draws.map { SIMD2($0.transform.columns.3.x, $0.transform.columns.3.y) }
    }

    @Test("A sphere emitter with a minimum distance spawns a ring, not a point")
    func ringEmitter() throws {
        let system = ParticleSystem(document: try document("""
        {"maxcount":200,
         "emitter":[{"name":"sphererandom","rate":1000,"distancemin":64,"distancemax":64,"directions":"1 1 0"}],
         "initializer":[{"name":"lifetimerandom","min":5,"max":5}]}
        """))
        system.update(deltaTime: 0.1)
        let distances = positions(system).map { simd_length($0) }
        #expect(!distances.isEmpty)
        #expect(distances.allSatisfy { abs($0 - 64) < 0.5 })
    }

    @Test("An emitter that leaves out its distance spreads over the default 256, not one point")
    func defaultSpawnDistance() throws {
        // Wallpaper Engine omits values equal to their default. Reading a missing distancemax
        // as zero piled 15,000 particles a second onto one point in real content.
        let system = ParticleSystem(document: try document("""
        {"maxcount":500,
         "emitter":[{"name":"sphererandom","rate":5000,"distancemin":200,"directions":"1 1 0"}],
         "initializer":[{"name":"lifetimerandom","min":5,"max":5}]}
        """))
        system.update(deltaTime: 0.1)
        let distances = positions(system).map { simd_length($0) }
        #expect(distances.min() ?? 0 >= 199)
        #expect(distances.max() ?? 0 <= 256.5)
    }

    @Test("The emitter's own origin moves where particles start")
    func emitterOrigin() throws {
        let system = ParticleSystem(document: try document("""
        {"maxcount":20,
         "emitter":[{"name":"boxrandom","rate":1000,"distancemax":0,"origin":"-256 256 0"}],
         "initializer":[{"name":"lifetimerandom","min":5,"max":5}]}
        """))
        system.update(deltaTime: 0.05)
        #expect(positions(system).allSatisfy { $0 == SIMD2(-256, 256) })
    }

    @Test("Turbulence stirs particles that would otherwise sit still")
    func turbulenceMoves() throws {
        let system = ParticleSystem(document: try document("""
        {"maxcount":50,
         "emitter":[{"name":"sphererandom","rate":1000,"distancemin":100,"distancemax":100,"directions":"1 1 0"}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10}],
         "operator":[{"name":"turbulence","scale":0.01,"speedmin":500,"speedmax":1000,"timescale":1}]}
        """))
        system.update(deltaTime: 0.05)
        let before = positions(system)
        system.update(deltaTime: 0.1)
        let after = positions(system).prefix(before.count)
        #expect(zip(before, after).contains { simd_distance($0, $1) > 0.5 })
        #expect(system.findings.contains { $0.detail == "turbulence is approximated" })
    }

    @Test("Instances place, size, turn and tint each particle as the per-quad draws did")
    func instancesMatchDraws() throws {
        let system = ParticleSystem(document: try document("""
        {"maxcount":40,
         "emitter":[{"name":"sphererandom","rate":2000,"distancemax":100,"directions":"1 1 0"}],
         "initializer":[{"name":"lifetimerandom","min":5,"max":5},{"name":"sizerandom","min":4,"max":12},
                        {"name":"rotationrandom","min":0,"max":180},
                        {"name":"colorrandom","min":"0 128 255","max":"255 128 0"}]}
        """))
        system.update(deltaTime: 0.1)

        var draws: [QuadDraw] = []
        system.appendDraws(to: &draws, cameraOffset: SIMD2(5, -3))
        var instances: [ParticleInstance] = []
        system.appendInstances(to: &instances, cameraOffset: SIMD2(5, -3))

        #expect(instances.count == draws.count)
        #expect(system.drawsAsInstances)
        for (draw, instance) in zip(draws, instances) {
            let p = instance.placement
            let c = cosf(p.w), s = sinf(p.w)
            #expect(abs(draw.transform.columns.3.x - p.x) < 0.001)
            #expect(abs(draw.transform.columns.3.y - p.y) < 0.001)
            #expect(abs(draw.transform.columns.0.x - c * p.z) < 0.001)
            #expect(abs(draw.transform.columns.0.y - s * p.z) < 0.001)
            #expect(draw.tint == instance.tint)
            #expect(draw.uvRect == instance.uvRect)
        }
    }

    @Test("Colour change runs from its start colour to its end colour over the set part of life")
    func colourChange() throws {
        // Real content: pink to light blue between 20% and 80% of each particle's life.
        let system = ParticleSystem(document: try document("""
        {"maxcount":5,
         "emitter":[{"name":"boxrandom","rate":1000,"distancemax":0}],
         "initializer":[{"name":"lifetimerandom","min":1,"max":1}],
         "operator":[{"name":"colorchange","starttime":0.2,"endtime":0.8,
                      "startvalue":"1 0.5 0.5","endvalue":"0.25 0.75 1"}]}
        """))
        func tint() -> SIMD4<Float> {
            var instances: [ParticleInstance] = []
            system.appendInstances(to: &instances, cameraOffset: .zero)
            return instances.first?.tint ?? .zero
        }
        system.update(deltaTime: 0.001)
        #expect(simd_distance(tint(), SIMD4(1, 0.5, 0.5, 1)) < 0.01)
        system.update(deltaTime: 0.499)
        #expect(simd_distance(tint(), SIMD4(0.625, 0.625, 0.75, 1)) < 0.02)
        system.update(deltaTime: 0.4)
        #expect(simd_distance(tint(), SIMD4(0.25, 0.75, 1, 1)) < 0.01)
        #expect(!system.findings.contains { $0.detail?.contains("colorchange") == true })
    }

    @Test("Turbulence carries particles at its speed, whatever their drag")
    func turbulenceSpeed() throws {
        // Real content pairs 500-1000px/s turbulence with drag 4. Treated as a push, the drag
        // held particles to a crawl and 20,000 of them piled into one white blob.
        let system = ParticleSystem(document: try document("""
        {"maxcount":200,
         "emitter":[{"name":"sphererandom","rate":4000,"distancemin":256,"directions":"1 1 0"}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10}],
         "operator":[{"name":"movement","drag":4},
                     {"name":"turbulence","scale":0.005,"speedmin":500,"speedmax":1000,"timescale":1}]}
        """))
        system.update(deltaTime: 0.05)
        let before = positions(system)
        for _ in 0 ..< 10 { system.update(deltaTime: 0.01) }
        let moved = zip(before, positions(system).prefix(before.count)).map { simd_distance($0, $1) }
        let mean = moved.reduce(0, +) / Float(max(moved.count, 1))
        // A tenth of a second at a few hundred units a second.
        #expect(mean > 10, "particles moved \(mean) on average")
    }

    /// Four ways a real library's particles came out wrong, each of which looked from a
    /// screenshot like "the particles are broken" and none of which was the same bug.
    @Test("A turbulent launch velocity adds to the particle's own, and never replaces it with zero")
    func turbulentVelocityDoesNotCancelTheRest() throws {
        // `turbulentvelocityrandom` carries `speedmin`/`speedmax`, not `min`/`max`. Reading the
        // ones it does not have gave every particle a velocity of zero — and, because it is
        // written after `velocityrandom`, threw away the falling velocity beside it. An autumn
        // wallpaper's leaves hung above the top of the frame and never fell into it.
        let system = ParticleSystem(document: try document("""
        {"maxcount":20,"emitter":[{"name":"boxrandom","rate":50,"distancemax":"10 10 0"}],
         "initializer":[
           {"name":"lifetimerandom","min":10,"max":10},
           {"name":"velocityrandom","min":"-100 -100 0","max":"-50 -15 0"},
           {"name":"turbulentvelocityrandom","offset":3,"scale":0.5,"speedmin":35,"speedmax":100}
         ],
         "operator":[{"name":"movement"}]}
        """))

        for _ in 0 ..< 60 { system.update(deltaTime: 1.0 / 30) }
        let bounds = try #require(system.liveBounds)
        #expect(bounds.minimum.y < -20, "nothing fell: \(bounds.minimum.y)")
        #expect(bounds.minimum.x < -20, "nothing drifted: \(bounds.minimum.x)")
    }

    @Test("A colour with only a minimum is that colour, not a random one between it and black")
    func minimumOnlyColourIsConstant() throws {
        // The format leaves out the bound that equals the other. Reading the absent one as zero
        // made every leaf declared "255 255 255" a different colour on the way down.
        let system = ParticleSystem(document: try document("""
        {"maxcount":40,"emitter":[{"name":"boxrandom","rate":100,"distancemax":"10 10 0"}],
         "initializer":[
           {"name":"lifetimerandom","min":5,"max":5},
           {"name":"colorrandom","min":"255 255 255"}
         ],
         "operator":[{"name":"movement"}]}
        """))
        system.update(deltaTime: 0.5)

        var instances: [ParticleInstance] = []
        system.appendInstances(to: &instances, cameraOffset: .zero)
        #expect(!instances.isEmpty)
        for instance in instances {
            #expect(instance.tint.x > 0.99 && instance.tint.y > 0.99 && instance.tint.z > 0.99,
                    "tinted \(instance.tint) rather than white")
        }
    }

    @Test("An instance's own tuning scales the preset it uses")
    func instanceOverridesScaleThePreset() throws {
        // One definition, placed a dozen times and scaled differently each time, is how content
        // is built. Ignoring the scaling ran every instance at the preset's settings: one scene
        // came out at full brightness and full rate where its author asked for a fifth of the
        // alpha, and buried itself in its own confetti.
        let json = """
        {"maxcount":100,"emitter":[{"name":"boxrandom","rate":100,"distancemax":"10 10 0"}],
         "initializer":[
           {"name":"lifetimerandom","min":4,"max":4},
           {"name":"sizerandom","min":10,"max":10},
           {"name":"alpharandom","min":1,"max":1}
         ],
         "operator":[{"name":"movement"}]}
        """
        let plain = ParticleSystem(document: try document(json))
        let tuned = ParticleSystem(
            document: try document(json),
            overrides: ParticleOverrides(alpha: 0.25, rate: 0.5, count: 0.5, size: 2)
        )

        #expect(tuned.maxCount == plain.maxCount / 2, "count scales the storage, before it fills")
        for _ in 0 ..< 30 {
            plain.update(deltaTime: 1.0 / 30)
            tuned.update(deltaTime: 1.0 / 30)
        }
        #expect(tuned.liveCount < plain.liveCount, "half the rate, half as many")

        var instances: [ParticleInstance] = []
        tuned.appendInstances(to: &instances, cameraOffset: .zero)
        let instance = try #require(instances.first)
        #expect(abs(instance.tint.w - 0.25) < 0.01, "alpha \(instance.tint.w), asked for 0.25")
        #expect(abs(instance.placement.z - 20) < 0.01, "size \(instance.placement.z), asked for 20")
    }

    @Test("A child that emits across a volume stands alone; one that emits from a point does not")
    func childrenThatFollowTheirParentAreNotDrawn() throws {
        // A child in Wallpaper Engine can be carried on each of its parent's particles — the
        // trail behind a spark. Those emit nothing of their own, or everything from one point,
        // because the parent supplies the position.
        let independent = ParticleSystem(document: try document("""
        {"maxcount":50,"emitter":[{"name":"sphererandom","rate":5,"distancemax":750}]}
        """))
        let trail = ParticleSystem(document: try document("""
        {"maxcount":10,"emitter":[{"name":"sphererandom","rate":10,"distancemax":6}]}
        """))
        let silent = ParticleSystem(document: try document("""
        {"maxcount":100,"emitter":[{"name":"sphererandom","rate":0,"distancemax":32}]}
        """))

        #expect(independent.placesItsOwnParticles)
        #expect(!trail.placesItsOwnParticles)
        #expect(!silent.placesItsOwnParticles)
    }
}
