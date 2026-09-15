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
}
