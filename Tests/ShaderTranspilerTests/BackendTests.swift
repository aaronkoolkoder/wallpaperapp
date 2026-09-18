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
