import Foundation
import Testing
@testable import WEFormat

/// What kind of thing a scene object is, which `scene.json` says by which key it carries
/// rather than by a type field.
@Suite("Scene object kinds")
struct SceneObjectKindTests {

    private func object(_ json: String) throws -> SceneObject {
        try JSONDecoder().decode(SceneObject.self, from: Data(json.utf8))
    }

    /// The bug this exists for: the editor writes the keys an object does not use as null, so
    /// a particle object carries `"image": null` beside its `"particle"`. Reading the bare
    /// presence of the key called every one of them an image object; each then failed to build
    /// as an image and was dropped. Across a real library of 114 wallpapers that silently
    /// deleted 65 particle systems — one scene of shooting stars, fireflies and embers rendered
    /// one emitter out of thirty-three, and looked simply empty.
    @Test("A null key is not a key: an object with image null and a particle is a particle")
    func nullKeysDoNotDecideTheKind() throws {
        let particle = try object("""
        {"id":20,"name":"Shooting star","image":null,
         "particle":"particles/presets/shootingstar.json","visible":true}
        """)
        #expect(particle.kind == .particle)
        #expect(particle.particle == "particles/presets/shootingstar.json")

        let text = try object("""
        {"id":21,"image":null,"particle":null,"text":"12:00"}
        """)
        #expect(text.kind == .text)

        let image = try object("""
        {"id":22,"image":"models/background.json","particle":null}
        """)
        #expect(image.kind == .image)

        let nothing = try object("""
        {"id":23,"image":null,"particle":null,"text":null}
        """)
        #expect(nothing.kind == .unknown)
    }

    /// Every field is a multiplier around 1, except the colour, which replaces.
    @Test("An instance's own tuning of a particle preset is read")
    func instanceOverridesAreRead() throws {
        let tuned = try object("""
        {"particle":"particles/presets/fireflies.json",
         "instanceoverride":{"id":755,"alpha":0.21,"count":2.0,"lifetime":1.52,
                             "rate":0.6,"size":0.53,"speed":0.85,
                             "colorn":"1.00000 0.00000 1.00000"}}
        """)
        let overrides = try #require(tuned.particleOverrides)
        #expect(overrides.alpha == 0.21)
        #expect(overrides.count == 2)
        #expect(overrides.rate == 0.6)
        #expect(overrides.size == 0.53)
        #expect(overrides.speed == 0.85)
        #expect(overrides.color == SIMD3(1, 0, 1))
        #expect(abs((overrides.lifetime ?? 0) - 1.52) < 0.001)

        // An empty one carries nothing, and is not worth holding on to.
        let empty = try object("""
        {"particle":"p.json","instanceoverride":{"id":1}}
        """)
        #expect(empty.particleOverrides == nil)
        let bare = try object("""
        {"particle":"p.json"}
        """)
        #expect(bare.particleOverrides == nil)
    }

    /// Content is untrusted: a negative rate or lifetime has no sensible meaning to fall back
    /// to, so the override is dropped and the preset's own value stands.
    @Test("A nonsense multiplier is ignored rather than applied")
    func nonsenseOverridesAreDropped() throws {
        let broken = try object("""
        {"particle":"p.json","instanceoverride":{"rate":-2,"size":0.5}}
        """)
        #expect(broken.particleOverrides?.rate == nil)
        #expect(broken.particleOverrides?.size == 0.5)
    }
}
