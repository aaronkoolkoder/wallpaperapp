import Foundation
import Testing
@testable import ShaderTranspiler

/// True when Scripts/vendor-shader-tools.sh has been run.
///
/// The toolchain is an optional build step, so these are skipped rather than failed on a clone
/// that has not vendored it — a red suite for a dependency someone has deliberately not built
/// teaches nothing and trains people to ignore failures.
private var toolchainAvailable: Bool {
    !(TranspilerBackendFactory.makeDefault() is UnavailableTranspilerBackend)
}

@Suite(
    "GlslangTranspilerBackend",
    .enabled(if: toolchainAvailable, "shader toolchain not vendored")
)
struct BackendTests {

    private let backend = GlslangTranspilerBackend()

    /// Shaped like a Wallpaper Engine image shader: a sampled texture, a tint, and the
    /// `g_`-prefixed uniforms the format uses throughout.
    private let wallpaperFragment = """
    #version 450

    layout(binding = 0) uniform sampler2D g_Texture0;

    layout(binding = 1) uniform Uniforms {
        vec4 g_Color;
        float g_Time;
        float g_Alpha;
    };

    layout(location = 0) in vec2 v_TexCoord;
    layout(location = 0) out vec4 fragColor;

    void main() {
        vec4 albedo = texture(g_Texture0, v_TexCoord);
        float pulse = 0.5 + 0.5 * sin(g_Time * 2.0);
        fragColor = vec4(albedo.rgb * g_Color.rgb * pulse, albedo.a * g_Alpha);
    }
    """

    private let wallpaperVertex = """
    #version 450

    layout(location = 0) in vec3 a_Position;
    layout(location = 1) in vec2 a_TexCoord;

    layout(binding = 0) uniform Matrices {
        mat4 g_ModelViewProjectionMatrix;
    };

    layout(location = 0) out vec2 v_TexCoord;

    void main() {
        v_TexCoord = a_TexCoord;
        gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
    }
    """

    @Test("Translates a fragment shader to Metal")
    func translatesFragment() throws {
        let msl = try backend.compileToMSL(glsl: wallpaperFragment, stage: .fragment)

        // Enough to show it is genuinely MSL rather than the GLSL echoed back.
        #expect(msl.contains("#include <metal_stdlib>"))
        #expect(msl.contains("fragment"))
        #expect(msl.contains("float4"))
        #expect(!msl.contains("#version 450"))
    }

    @Test("Translates a vertex shader to Metal")
    func translatesVertex() throws {
        let msl = try backend.compileToMSL(glsl: wallpaperVertex, stage: .vertex)
        #expect(msl.contains("#include <metal_stdlib>"))
        #expect(msl.contains("vertex"))
        #expect(msl.contains("float4x4"))
    }

    @Test("Texture sampling survives the round trip")
    func preservesSampling() throws {
        let msl = try backend.compileToMSL(glsl: wallpaperFragment, stage: .fragment)
        // GLSL's `texture()` becomes a Metal sampler call; if this is missing the shader
        // compiled but would render nothing.
        #expect(msl.contains("sample"))
        #expect(msl.contains("texture2d"))
    }

    @Test("Uniform names survive, so bindings can be matched up")
    func preservesUniformNames() throws {
        let msl = try backend.compileToMSL(glsl: wallpaperFragment, stage: .fragment)
        #expect(msl.contains("g_Color"))
        #expect(msl.contains("g_Time"))
    }

    @Test("A syntax error is reported, not swallowed")
    func reportsSyntaxErrors() {
        let broken = "#version 450\nvoid main() { this is not glsl }"
        #expect(throws: TranspilerBackendError.self) {
            try backend.compileToMSL(glsl: broken, stage: .fragment)
        }
    }

    @Test("The error says what went wrong")
    func errorCarriesDetail() {
        do {
            _ = try backend.compileToMSL(
                glsl: "#version 450\nvoid main() { undefinedFunction(); }", stage: .fragment
            )
            Issue.record("expected a failure")
        } catch let error as TranspilerBackendError {
            guard case .translationFailed(_, let detail) = error else {
                Issue.record("expected a translation failure")
                return
            }
            // A bare "compilation failed" would make a broken wallpaper undiagnosable.
            #expect(!detail.isEmpty)
            #expect(detail.count > 10)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Empty input fails rather than producing an empty shader")
    func rejectsEmptyInput() {
        #expect(throws: (any Error).self) {
            try backend.compileToMSL(glsl: "", stage: .fragment)
        }
    }

    @Test("Translation is deterministic")
    func deterministic() throws {
        // Output is cached by content hash, so two runs producing different MSL would mean the
        // cache never hits and every launch recompiles.
        let first = try backend.compileToMSL(glsl: wallpaperFragment, stage: .fragment)
        let second = try backend.compileToMSL(glsl: wallpaperFragment, stage: .fragment)
        #expect(first == second)
    }

    @Test("Repeated use does not trip glslang's one-time global setup")
    func repeatedUseIsSafe() throws {
        // glslang keeps process-global state initialised exactly once; getting that wrong shows
        // up only under repeated or concurrent compilation.
        for _ in 0 ..< 12 {
            _ = try GlslangTranspilerBackend().compileToMSL(
                glsl: wallpaperFragment, stage: .fragment
            )
        }
    }

    @Test("The factory picks the real backend when the toolchain is present")
    func factorySelectsWorkingBackend() throws {
        let backend = TranspilerBackendFactory.makeDefault()
        #expect(!(backend is UnavailableTranspilerBackend))
    }

}

@Suite("TranspilerBackend fallback")
struct BackendFallbackTests {

    @Test("The stand-in reports why it cannot work")
    func unavailableExplainsItself() {
        #expect(throws: TranspilerBackendError.notVendored) {
            try UnavailableTranspilerBackend().compileToMSL(glsl: "x", stage: .fragment)
        }
    }

    @Test("The factory always returns something usable")
    func factoryNeverReturnsNil() {
        // Whether or not the toolchain is present, callers get a backend rather than an
        // optional they have to reason about.
        _ = TranspilerBackendFactory.makeDefault()
    }
}

/// End-to-end: a shader written the way Wallpaper Engine ships them, through the preprocessor
/// and into Metal.
@Suite(
    "Preprocessor and backend together",
    .enabled(if: toolchainAvailable, "shader toolchain not vendored")
)
struct PipelineTests {

    private let backend = GlslangTranspilerBackend()
    private let preprocessor = ShaderPreprocessor()

    /// Legacy qualifiers, removed builtins, annotated uniforms, combos and an include — every
    /// construct that makes shipped content fail to compile as written.
    private let legacyFragment = #"""
    #include "common.h"

    // [COMBO] {"combo":"BLOOM","default":1}

    varying vec2 v_TexCoord;
    varying vec4 v_Color;

    uniform sampler2D g_Texture0; // {"material":"framebuffer"}
    uniform sampler2D g_Noise;    // {"material":"noise"}

    uniform vec4 g_Tint;      // {"material":"tint","default":"1 1 1 1","type":"color"}
    uniform float g_Speed;    // {"material":"speed","default":"0.25","range":[0,2]}
    uniform vec3 g_Direction; // {"material":"direction","default":"0 1 0"}
    uniform float g_Time;
    uniform mat4 g_ModelViewProjection;

    void main() {
        vec2 uv = v_TexCoord + CAST2(g_Time * g_Speed) * g_Direction.xy;
        vec4 noise = texture2D(g_Noise, uv);
    #if BLOOM
        noise.rgb += CAST3(0.15);
    #endif
        gl_FragColor = texture2D(g_Texture0, uv) * g_Tint * v_Color * saturate(noise.r);
    }
    """#

    private let common = """
    #define CAST2(x) (vec2(x))
    #define CAST3(x) (vec3(x))
    float saturate(float v) { return clamp(v, 0.0, 1.0); }
    """

    private func preprocessed() throws -> PreprocessedShader {
        try preprocessor.preprocess(
            ShaderSource(name: "water.frag", stage: .fragment, text: legacyFragment),
            provider: InMemoryShaderFileProvider(["common.h": common])
        )
    }

    @Test("A shader in Wallpaper Engine's dialect compiles to Metal")
    func compilesLegacyShader() throws {
        let translated = try backend.compile(glsl: try preprocessed().glsl, stage: .fragment)
        #expect(translated.msl.contains("#include <metal_stdlib>"))
        #expect(translated.msl.contains("fragment"))
        #expect(translated.msl.contains("sample"))
    }

    @Test("The computed std140 layout matches the one the translator emitted")
    func layoutAgreesWithTranslator() throws {
        // This is the invariant every uniform write depends on. `UniformBlockLayout` computes
        // offsets from the published std140 rules without the toolchain; SPIRV-Cross bakes its
        // own into the generated struct. If the two ever disagree, every uniform after the
        // first mismatch is written to the wrong place and the shader renders nonsense rather
        // than failing.
        let shader = try preprocessed()
        let translated = try backend.compile(glsl: shader.glsl, stage: .fragment)

        #expect(!shader.layout.members.isEmpty)
        #expect(!translated.reflection.members.isEmpty)

        for member in shader.layout.members {
            guard let reported = translated.reflection.members.first(where: { $0.name == member.name }) else {
                Issue.record("the translator dropped \(member.name)")
                continue
            }
            #expect(
                member.offset == reported.offset,
                "\(member.name) is at +\(member.offset) here and +\(reported.offset) there"
            )
        }
    }

    @Test("Binding slots come from the translator, not from declaration order")
    func bindingsFollowReflection() throws {
        // SPIRV-Cross renumbers into compact Metal slots and drops what the shader never
        // reads, so the second declared sampler becomes texture(0) when the first is unused.
        // Anything that bound by declaration index would swap them.
        let source = """
        uniform sampler2D g_Unused;
        uniform sampler2D g_Used;
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = texture2D(g_Used, v_TexCoord); }
        """
        let shader = try preprocessor.preprocess(
            ShaderSource(name: "bind.frag", stage: .fragment, text: source),
            provider: InMemoryShaderFileProvider([:])
        )
        let translated = try backend.compile(glsl: shader.glsl, stage: .fragment)

        #expect(shader.samplers.map(\.name) == ["g_Unused", "g_Used"])
        #expect(translated.reflection.textureSlot(for: "g_Used") == 0)
        #expect(translated.reflection.textureSlot(for: "g_Unused") == nil)
    }

    @Test("Each combo variant translates to different Metal")
    func combosChangeOutput() throws {
        // If the variants produced identical MSL the combo would be doing nothing, and the
        // content hash that keys the cache would be the only thing distinguishing them.
        func translate(bloom: Int) throws -> String {
            let shader = try preprocessor.preprocess(
                ShaderSource(name: "water.frag", stage: .fragment, text: legacyFragment),
                provider: InMemoryShaderFileProvider(["common.h": common]),
                comboOverrides: ["BLOOM": bloom]
            )
            return try backend.compile(glsl: shader.glsl, stage: .fragment).msl
        }
        #expect(try translate(bloom: 0) != (try translate(bloom: 1)))
    }

    @Test("A paired vertex and fragment shader agree on their varyings")
    func pairedStagesAgree() throws {
        let (vertex, fragment) = try preprocessor.preprocessPair(
            vertex: ShaderSource(name: "p.vert", stage: .vertex, text: """
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            varying vec4 v_Color;
            uniform mat4 g_ModelViewProjection;
            void main() {
                v_TexCoord = a_TexCoord;
                v_Color = vec4(1.0);
                gl_Position = g_ModelViewProjection * vec4(a_Position, 1.0);
            }
            """),
            fragment: ShaderSource(name: "p.frag", stage: .fragment, text: """
            varying vec4 v_Color;
            varying vec2 v_TexCoord;
            uniform sampler2D g_Texture0;
            void main() { gl_FragColor = texture2D(g_Texture0, v_TexCoord) * v_Color; }
            """),
            provider: InMemoryShaderFileProvider([:])
        )

        let vertexOut = try backend.compile(glsl: vertex.glsl, stage: .vertex).reflection
        let fragmentIn = try backend.compile(glsl: fragment.glsl, stage: .fragment).reflection

        // The fragment shader's inputs must land on the locations the vertex shader wrote, or
        // it reads whichever varying happened to take that slot.
        for input in fragmentIn.inputs {
            #expect(
                vertex.varyings.contains(input.name),
                "the fragment stage reads \(input.name), which the vertex stage does not write"
            )
        }
        #expect(!vertexOut.entryPoint.isEmpty)
        #expect(Set(fragmentIn.inputs.map(\.location)).count == fragmentIn.inputs.count)
    }

    @Test("A compiler error points at the line the author wrote")
    func errorsMapBackToSource() throws {
        // The prologue shifts every line and includes are flattened, so the raw number names a
        // line in a file nobody can open.
        let shader = try preprocessor.preprocess(
            ShaderSource(name: "broken.frag", stage: .fragment, text: """
            varying vec2 v_TexCoord;
            void main() { thisFunctionDoesNotExist(); }
            """),
            provider: InMemoryShaderFileProvider([:])
        )

        do {
            _ = try backend.compile(glsl: shader.glsl, stage: .fragment)
            Issue.record("expected the broken shader to fail")
        } catch let error as TranspilerBackendError {
            guard case .translationFailed(_, let detail) = error else {
                Issue.record("expected a translation failure")
                return
            }
            // glslang reports `ERROR: 0:<line>:`; that line must map back into the original.
            let reported = detail.matches(of: /0:(\d+):/).compactMap { Int($0.1) }
            #expect(!reported.isEmpty)
            for line in reported {
                #expect(shader.origin(ofEmittedLine: line)?.line == 2)
            }
        }
    }
}
