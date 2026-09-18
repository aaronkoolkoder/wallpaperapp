import Foundation
import Metal
import MetalRenderer
import ShaderTranspiler
import Testing
import WEFormat
@testable import SceneEngine

/// Which sampler a material's texture slot feeds.
@Suite("Material texture slots")
struct MaterialTextureSlotTests {

    @Test("The conventional name wins over declaration order")
    func prefersConventionalName() {
        // The case that matters: a `#if`-guarded mask declared above `g_Texture0`. Taking the
        // nth declared sampler would bind the colour map to `g_Mask`, which the shader does not
        // read when the combo is off, and the layer renders flat white.
        let declared = ["g_Mask", "g_Texture0", "g_Texture1"]
        #expect(SceneBuilder.samplerName(forTextureSlot: 0, declared: declared) == "g_Texture0")
        #expect(SceneBuilder.samplerName(forTextureSlot: 1, declared: declared) == "g_Texture1")
    }

    @Test("A shader naming its samplers something else falls back to order")
    func fallsBackToDeclarationOrder() {
        let declared = ["g_Albedo", "g_Normal"]
        #expect(SceneBuilder.samplerName(forTextureSlot: 0, declared: declared) == "g_Albedo")
        #expect(SceneBuilder.samplerName(forTextureSlot: 1, declared: declared) == "g_Normal")
    }

    @Test("The fallback skips samplers that are themselves g_Texture*")
    func fallbackIgnoresConventionalNames() {
        // A shader declaring `g_Texture1` but not `g_Texture0` must not have slot 0 fall through
        // onto `g_Texture1` — that would bind the colour map to the second texture.
        let declared = ["g_Texture1"]
        #expect(SceneBuilder.samplerName(forTextureSlot: 0, declared: declared) == "g_Texture0")
        #expect(SceneBuilder.samplerName(forTextureSlot: 1, declared: declared) == "g_Texture1")
    }

    @Test("A slot past everything declared keeps the conventional name")
    func beyondDeclared() {
        #expect(SceneBuilder.samplerName(forTextureSlot: 3, declared: ["g_Albedo"]) == "g_Texture3")
        #expect(SceneBuilder.samplerName(forTextureSlot: 0, declared: []) == "g_Texture0")
    }
}

@Suite(
    "Conditional shaders",
    .enabled(if: gpuAndToolchainAvailable, "needs a GPU and the vendored shader toolchain")
)
struct ConditionalShaderTests {

    /// A shader whose first-declared sampler is switched off by a combo — the shape that makes
    /// declaration order and the `g_TextureN` convention disagree.
    private func makeWallpaper(mask: Int) throws -> SceneAssets {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaCond-\(UUID().uuidString)", isDirectory: true)
        let shaders = root.appendingPathComponent("shaders", isDirectory: true)
        try FileManager.default.createDirectory(at: shaders, withIntermediateDirectories: true)

        try """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        uniform mat4 g_ModelViewProjection;
        void main() {
            v_TexCoord = a_TexCoord;
            gl_Position = g_ModelViewProjection * vec4(a_Position, 1.0);
        }
        """.write(to: shaders.appendingPathComponent("c.vert"), atomically: true, encoding: .utf8)

        try #"""
        // [COMBO] {"combo":"HAS_MASK","default":\#(mask)}
        varying vec2 v_TexCoord;
        #if HAS_MASK
        uniform sampler2D g_Mask;
        #endif
        uniform sampler2D g_Texture0;
        void main() {
            vec4 base = texture2D(g_Texture0, v_TexCoord);
        #if HAS_MASK
            base *= texture2D(g_Mask, v_TexCoord).r;
        #endif
            gl_FragColor = base;
        }
        """#.write(to: shaders.appendingPathComponent("c.frag"), atomically: true, encoding: .utf8)

        return SceneAssets(wallpaperID: "cond", directory: root, packageURL: nil)
    }

    @Test("A sampler switched off by a combo is compiled out and not bound")
    func maskOffLeavesOneSampler() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        let program = try compiler.program(
            for: MaterialPass(shader: "c", textures: ["materials/colour"]),
            assets: try makeWallpaper(mask: 0)
        )

        // The parser does not evaluate `#if`, so both samplers are declared as far as it knows —
        // which is precisely why binding by declaration order would be wrong here.
        #expect(program.declaredSamplers == ["g_Mask", "g_Texture0"])
        // The translator eliminated the one the shader never reads.
        #expect(program.textureSlots["g_Texture0"] == 0)
        #expect(program.textureSlots["g_Mask"] == nil)
        // And the material's first texture is routed to the one that survives.
        #expect(
            SceneBuilder.samplerName(forTextureSlot: 0, declared: program.declaredSamplers)
                == "g_Texture0"
        )
    }

    @Test("Turning the combo on brings the sampler back")
    func maskOnKeepsBothSamplers() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        let program = try compiler.program(
            for: MaterialPass(shader: "c", textures: ["materials/colour"], combos: ["HAS_MASK": 1]),
            assets: try makeWallpaper(mask: 0)
        )

        #expect(program.textureSlots["g_Mask"] != nil)
        #expect(program.textureSlots["g_Texture0"] != nil)
        // Both survive, and they must not collide on one slot.
        #expect(program.textureSlots["g_Mask"] != program.textureSlots["g_Texture0"])
    }

    @Test("A conditional shader compiles for both variants")
    func bothVariantsCompile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = MaterialCompiler(device: device, cache: ShaderCache(directory: nil))
        let assets = try makeWallpaper(mask: 0)

        _ = try compiler.program(for: MaterialPass(shader: "c", combos: ["HAS_MASK": 0]), assets: assets)
        _ = try compiler.program(for: MaterialPass(shader: "c", combos: ["HAS_MASK": 1]), assets: assets)
        #expect(compiler.compiledProgramCount == 2)
    }
}
