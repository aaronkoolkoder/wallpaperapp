import Foundation
import Testing
@testable import ShaderTranspiler

/// Combos that switch on when a texture is bound, rather than being declared as `[COMBO]`.
///
/// Wallpaper Engine's optional textures — painted masks above all — are written as a sampler
/// annotated `{"combo":"MASK"}` with the code that reads it inside `#if MASK == 1`. Nothing
/// defined MASK, so that code was always compiled out and every painted mask was ignored.
@Suite("Sampler combos")
struct SamplerComboTests {

    private let preprocessor = ShaderPreprocessor()

    private static let fragment = """
    varying vec2 v_TexCoord;
    uniform sampler2D g_Texture0;
    uniform sampler2D g_Texture1; // {"material":"mask","combo":"MASK","default":"util/white"}
    void main() {
        vec4 colour = texture2D(g_Texture0, v_TexCoord);
    #if MASK == 1
        colour.a *= texture2D(g_Texture1, v_TexCoord).r;
    #endif
        gl_FragColor = colour;
    }
    """

    /// The vertex stage tests MASK too, but never declares the sampler — as foliage sway does.
    private static let vertex = """
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;
    uniform mat4 g_ModelViewProjection;
    void main() {
    #if MASK == 1
        v_TexCoord = a_TexCoord * 0.5;
    #else
        v_TexCoord = a_TexCoord;
    #endif
        gl_Position = g_ModelViewProjection * vec4(a_Position, 1.0);
    }
    """

    private func pair(bound: Set<Int>, combos: [String: Int] = [:]) throws
        -> (vertex: PreprocessedShader, fragment: PreprocessedShader)
    {
        try preprocessor.preprocessPair(
            vertex: ShaderSource(name: "m.vert", stage: .vertex, text: Self.vertex),
            fragment: ShaderSource(name: "m.frag", stage: .fragment, text: Self.fragment),
            provider: InMemoryShaderFileProvider([:]),
            comboOverrides: combos,
            boundTextures: bound
        )
    }

    @Test("The annotation's combo is kept on the sampler")
    func parsesTheCombo() {
        let result = UniformAnnotationParser.parse(Self.fragment, shaderName: "m.frag")
        #expect(result.samplers.first { $0.name == "g_Texture1" }?.combo == "MASK")
        #expect(result.samplers.first { $0.name == "g_Texture0" }?.combo == nil)
    }

    @Test("Binding the mask switches its combo on in both stages")
    func boundTextureDefinesTheCombo() throws {
        let (vertex, fragment) = try pair(bound: [0, 1])
        #expect(fragment.glsl.contains("#define MASK 1"))
        // The vertex stage never declares g_Texture1; it must still agree with the fragment
        // stage, or the mask's UV is computed for one variant and read by the other.
        #expect(vertex.glsl.contains("#define MASK 1"))
    }

    @Test("Without a mask the combo is defined as off, not left undefined")
    func unboundTextureDefinesZero() throws {
        let (vertex, fragment) = try pair(bound: [0])
        #expect(fragment.glsl.contains("#define MASK 0"))
        #expect(vertex.glsl.contains("#define MASK 0"))
    }

    @Test("A material that sets the combo outright wins over the texture")
    func explicitOverrideWins() throws {
        let (_, fragment) = try pair(bound: [0, 1], combos: ["MASK": 0])
        #expect(fragment.glsl.contains("#define MASK 0"))
    }

    @Test("The two variants are different programs")
    func variantsDiffer() throws {
        // The cache is keyed on the emitted source; if both variants hashed alike, the first
        // one compiled would be served for both.
        #expect(try pair(bound: [0, 1]).fragment.sourceHash != (try pair(bound: [0]).fragment.sourceHash))
    }
}
