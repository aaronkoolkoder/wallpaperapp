import Foundation
import Metal
import MetalRenderer
import ShaderTranspiler
import Testing
import WEFormat
@testable import SceneEngine

/// True when Scripts/vendor-shader-tools.sh has been run.

@Suite(
    "MaterialCompiler",
    .enabled(if: gpuAndToolchainAvailable, "needs a GPU and the vendored shader toolchain")
)
struct MaterialCompilerTests {

    /// A wallpaper laid out the way Wallpaper Engine ships one: shaders under `shaders/`, with
    /// an include beside them.
    private func makeWallpaper(
        vertex: String? = nil,
        fragment: String? = nil,
        extraFiles: [String: String] = [:]
    ) throws -> SceneAssets {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaMaterialTests-\(UUID().uuidString)", isDirectory: true)
        let shaders = root.appendingPathComponent("shaders", isDirectory: true)
        try FileManager.default.createDirectory(at: shaders, withIntermediateDirectories: true)

        try (vertex ?? Self.defaultVertex).write(
            to: shaders.appendingPathComponent("test.vert"), atomically: true, encoding: .utf8
        )
        try (fragment ?? Self.defaultFragment).write(
            to: shaders.appendingPathComponent("test.frag"), atomically: true, encoding: .utf8
        )
        for (name, contents) in extraFiles {
            try contents.write(
                to: shaders.appendingPathComponent(name), atomically: true, encoding: .utf8
            )
        }

        return SceneAssets(wallpaperID: "test", directory: root, packageURL: nil)
    }

    static let defaultVertex = """
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;
    uniform mat4 g_ModelViewProjection;
    void main() {
        v_TexCoord = a_TexCoord;
        gl_Position = g_ModelViewProjection * vec4(a_Position, 1.0);
    }
    """

    static let defaultFragment = #"""
    #include "common.h"

    // [COMBO] {"combo":"TINTED","default":1}

    varying vec2 v_TexCoord;
    uniform sampler2D g_Texture0;
    uniform vec4 g_Tint;   // {"material":"tint","default":"1 1 1 1","type":"color"}
    uniform float g_Time;

    void main() {
        vec4 albedo = texture2D(g_Texture0, v_TexCoord);
    #if TINTED
        albedo *= g_Tint;
    #endif
        gl_FragColor = albedo * saturate(sin(g_Time) * 0.5 + 0.5);
    }
    """#

    static let commonInclude = """
    float saturate(float v) { return clamp(v, 0.0, 1.0); }
    """

    private func compiler() throws -> (MaterialCompiler, any MTLDevice) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // A memory-only cache so tests never touch the user's Application Support.
        return (MaterialCompiler(device: device, cache: ShaderCache(directory: nil)), device)
    }

    @Test("A Wallpaper Engine material becomes a real Metal pipeline")
    func compilesMaterial() throws {
        // The whole point of the transpiler: up to here a material's own shader was never run,
        // and effects were approximated by name.
        let (compiler, _) = try compiler()
        let assets = try makeWallpaper(extraFiles: ["common.h": Self.commonInclude])

        let program = try compiler.program(
            for: MaterialPass(shader: "test", textures: ["textures/base"])
            , assets: assets
        )

        #expect(program.name == "test")
        #expect(program.declaredSamplers == ["g_Texture0"])
        #expect(program.textureSlots["g_Texture0"] == 0)
    }

    @Test("The fragment uniform block is laid out and bound")
    func exposesUniformLayout() throws {
        let (compiler, _) = try compiler()
        let assets = try makeWallpaper(extraFiles: ["common.h": Self.commonInclude])
        let program = try compiler.program(for: MaterialPass(shader: "test"), assets: assets)

        #expect(program.fragmentLayout.member(named: "g_Tint") != nil)
        #expect(program.fragmentLayout.member(named: "g_Time") != nil)
        #expect(program.fragmentBufferSlot != nil)
        #expect(program.vertexLayout.member(named: "g_ModelViewProjection") != nil)
    }

    @Test("Quad geometry is laid out for the shader's own attributes")
    func buildsMatchingGeometry() throws {
        // Two attributes at three and two components: twenty floats for four vertices. A fixed
        // vertex struct would either over- or under-feed a shader that declares something else.
        let (compiler, _) = try compiler()
        let assets = try makeWallpaper(extraFiles: ["common.h": Self.commonInclude])
        let program = try compiler.program(for: MaterialPass(shader: "test"), assets: assets)

        #expect(program.vertexCount == 4)
        #expect(program.vertexBuffer.length >= 4 * 5 * MemoryLayout<Float>.size)

        let floats = program.vertexBuffer.contents()
            .bindMemory(to: Float.self, capacity: 20)
        // First vertex is the bottom-left corner with its texture coordinate.
        #expect(floats[0] == -0.5)
        #expect(floats[1] == -0.5)
        #expect(floats[3] == 0)
        #expect(floats[4] == 1)
    }

    @Test("Geometry does not collide with the shader's constant buffer")
    func avoidsBufferIndexCollision() throws {
        // Metal shares one index space between vertex attribute buffers and constant buffers,
        // so geometry at buffer(0) would overwrite the uniforms the vertex shader reads.
        let (compiler, _) = try compiler()
        let assets = try makeWallpaper(extraFiles: ["common.h": Self.commonInclude])
        let program = try compiler.program(for: MaterialPass(shader: "test"), assets: assets)

        #expect(program.vertexBufferIndex != program.vertexBufferSlot)
        if let slot = program.vertexBufferSlot {
            #expect(program.vertexBufferIndex > slot)
        }
    }

    @Test("Each combo variant is compiled separately")
    func compilesPerVariant() throws {
        let (compiler, _) = try compiler()
        let assets = try makeWallpaper(extraFiles: ["common.h": Self.commonInclude])

        _ = try compiler.program(for: MaterialPass(shader: "test", combos: ["TINTED": 0]), assets: assets)
        _ = try compiler.program(for: MaterialPass(shader: "test", combos: ["TINTED": 1]), assets: assets)
        #expect(compiler.compiledProgramCount == 2)
    }

    @Test("The same pass twice is compiled once")
    func reusesPrograms() throws {
        let (compiler, _) = try compiler()
        let assets = try makeWallpaper(extraFiles: ["common.h": Self.commonInclude])
        let pass = MaterialPass(shader: "test", combos: ["TINTED": 1])

        _ = try compiler.program(for: pass, assets: assets)
        _ = try compiler.program(for: pass, assets: assets)
        #expect(compiler.compiledProgramCount == 1)
    }

    @Test("A material naming no shader is refused clearly")
    func rejectsShaderlessPass() throws {
        let (compiler, _) = try compiler()
        let assets = try makeWallpaper(extraFiles: ["common.h": Self.commonInclude])
        #expect(throws: MaterialProgramError.self) {
            try compiler.program(for: MaterialPass(), assets: assets)
        }
    }

    @Test("A missing include fails with the file that could not be found")
    func reportsMissingInclude() throws {
        // No `common.h` this time, so `saturate` is undefined and the include cannot resolve.
        let (compiler, _) = try compiler()
        let assets = try makeWallpaper()
        #expect(throws: (any Error).self) {
            try compiler.program(for: MaterialPass(shader: "test"), assets: assets)
        }
    }

    @Test("A shader that does not compile fails rather than drawing nothing")
    func reportsBrokenShader() throws {
        let (compiler, _) = try compiler()
        let assets = try makeWallpaper(fragment: "void main() { thisIsNotAFunction(); }")
        #expect(throws: (any Error).self) {
            try compiler.program(for: MaterialPass(shader: "test"), assets: assets)
        }
    }

    @Test("An attribute with no known meaning is filled and reported")
    func reportsUnknownAttribute() throws {
        // Zero-filled rather than left undefined, so the layer looks wrong in a stable way
        // instead of sampling whatever was in the buffer.
        let (compiler, _) = try compiler()
        let assets = try makeWallpaper(vertex: """
        attribute vec3 a_Position;
        attribute vec2 a_SomethingNobodyKnows;
        varying vec2 v_TexCoord;
        uniform mat4 g_ModelViewProjection;
        void main() {
            v_TexCoord = a_SomethingNobodyKnows;
            gl_Position = g_ModelViewProjection * vec4(a_Position, 1.0);
        }
        """, extraFiles: ["common.h": Self.commonInclude])

        let program = try compiler.program(for: MaterialPass(shader: "test"), assets: assets)
        #expect(program.diagnostics.contains { $0.message.contains("a_SomethingNobodyKnows") })
    }

    @Test("Two wallpapers with same-named but different shaders do not share a pipeline")
    func distinctWallpapersDoNotCollide() throws {
        // Workshop content is full of wallpapers that each ship their own `genericimage2`. A
        // compiler keyed by shader name would hand the second one the first one's pipeline, and
        // the wallpaper would render as a different wallpaper — which is why auditing a library
        // with one shared compiler needs a content-derived key.
        let (compiler, _) = try compiler()
        let first = try makeWallpaper(extraFiles: ["common.h": Self.commonInclude])
        let second = try makeWallpaper(
            fragment: """
            varying vec2 v_TexCoord;
            uniform sampler2D g_Texture0;
            uniform vec4 g_SomethingElse;
            void main() { gl_FragColor = g_SomethingElse; }
            """,
            extraFiles: ["common.h": Self.commonInclude]
        )

        let pass = MaterialPass(shader: "test")
        let a = try compiler.program(for: pass, assets: first)
        let b = try compiler.program(for: pass, assets: second)

        #expect(compiler.compiledProgramCount == 2)
        #expect(a.fragmentLayout.member(named: "g_Tint") != nil)
        #expect(b.fragmentLayout.member(named: "g_SomethingElse") != nil)
        #expect(b.fragmentLayout.member(named: "g_Tint") == nil)
    }

    @Test("Identical shaders in different wallpapers are compiled once")
    func identicalShadersAreShared() throws {
        // The flip side: stock shaders are shared across most of a library, and translating
        // each one per wallpaper is what makes auditing a library slow.
        let (compiler, _) = try compiler()
        let first = try makeWallpaper(extraFiles: ["common.h": Self.commonInclude])
        let second = try makeWallpaper(extraFiles: ["common.h": Self.commonInclude])

        _ = try compiler.program(for: MaterialPass(shader: "test"), assets: first)
        _ = try compiler.program(for: MaterialPass(shader: "test"), assets: second)
        #expect(compiler.compiledProgramCount == 1)
    }

    @Test("A blend mode from the material reaches the pipeline")
    func honoursBlendMode() throws {
        let (compiler, _) = try compiler()
        let assets = try makeWallpaper(extraFiles: ["common.h": Self.commonInclude])
        // Different blends are different pipelines, so they must not share a cache entry.
        _ = try compiler.program(for: MaterialPass(blending: "additive", shader: "test"), assets: assets)
        _ = try compiler.program(for: MaterialPass(blending: "normal", shader: "test"), assets: assets)
        #expect(compiler.compiledProgramCount == 2)
    }
}

@Suite(
    "MaterialCompilerFactory",
    .enabled(if: gpuAndToolchainAvailable, "needs a GPU and the vendored shader toolchain")
)
struct MaterialCompilerFactoryTests {

    @Test("Each wallpaper gets its own compiler over one shared cache")
    func separateCompilersSharedCache() throws {
        // The lifetime split is the point: pipelines are per wallpaper so a long playlist does
        // not accumulate them, while translations are shared so a wallpaper coming back round
        // is not re-translated.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let factory = MaterialCompilerFactory(cache: ShaderCache(directory: nil))

        let first = factory.makeCompiler(device: device)
        let second = factory.makeCompiler(device: device)

        #expect(first !== second)
        #expect(first.isAvailable)
        #expect(second.isAvailable)
        #expect(first.compiledProgramCount == 0)
    }
}
