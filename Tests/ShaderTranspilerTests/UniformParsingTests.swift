import Foundation
import Testing
@testable import ShaderTranspiler

@Suite("UniformAnnotationParser")
struct UniformAnnotationParserTests {

    private func parse(_ text: String) -> UniformParseResult {
        UniformAnnotationParser.parse(text, shaderName: "test.frag")
    }

    @Test("Reads an annotated uniform the way Wallpaper Engine writes one")
    func readsAnnotated() {
        let result = parse(#"""
        uniform vec4 g_Tint; // {"material":"tint","label":"ui_editor_properties_tint","default":"1 0.5 0 1","type":"color"}
        """#)

        #expect(result.uniforms.count == 1)
        let uniform = try? #require(result.uniforms.first)
        #expect(uniform?.name == "g_Tint")
        #expect(uniform?.type == .vec4)
        #expect(uniform?.material == "tint")
        #expect(uniform?.label == "ui_editor_properties_tint")
        #expect(uniform?.editor == .color)
        #expect(uniform?.defaultValue == .vector([1, 0.5, 0, 1]))
        #expect(uniform?.isUnannotated == false)
    }

    @Test("A bare uniform is marked as one the host has to supply")
    func marksUnannotated() {
        // Engine-supplied uniforms carry no annotation, and that absence is the only signal
        // that the app rather than the user provides the value.
        let result = parse("uniform mat4 g_ModelViewProjection;")
        #expect(result.uniforms.first?.isUnannotated == true)
        #expect(result.uniforms.first?.material == nil)
    }

    @Test("Defaults are read against the declared type, not the JSON shape")
    func readsDefaultsByType() {
        // All three spellings occur in shipped content for the same kind of value.
        let result = parse(#"""
        uniform float a; // {"default":0.25}
        uniform float b; // {"default":"0.25"}
        uniform vec3 c;  // {"default":"1 2 3"}
        uniform vec2 d;  // {"default":[4,5]}
        uniform int e;   // {"default":"7"}
        uniform bool f;  // {"default":1}
        """#)

        #expect(result.uniforms[0].defaultValue == .scalar(0.25))
        #expect(result.uniforms[1].defaultValue == .scalar(0.25))
        #expect(result.uniforms[2].defaultValue == .vector([1, 2, 3]))
        #expect(result.uniforms[3].defaultValue == .vector([4, 5]))
        #expect(result.uniforms[4].defaultValue == .integer(7))
        #expect(result.uniforms[5].defaultValue == .boolean(true))
    }

    @Test("A default with too few components is padded rather than dropped")
    func padsShortDefaults() {
        // A partially-correct colour is closer to the author's intent than black.
        let result = parse(#"uniform vec4 g_Tint; // {"default":"1 1 1"}"#)
        #expect(result.uniforms.first?.defaultValue == .vector([1, 1, 1, 0]))
    }

    @Test("An unsupported type is reported rather than skipped quietly")
    func reportsUnsupportedType() {
        // Silently dropping one would shift the std140 offset of everything after it, which
        // corrupts the whole shader rather than one property.
        let result = parse("uniform dmat2x3 g_Exotic;")
        #expect(result.uniforms.isEmpty)
        #expect(result.diagnostics.contains { $0.severity == .unsupported })
    }

    @Test("A multi-declarator line is reported, not half-read")
    func reportsMultipleDeclarators() {
        let result = parse("uniform float a, b;")
        #expect(result.uniforms.isEmpty)
        #expect(result.diagnostics.contains { $0.kind == .unrecognizedConstruct })
    }

    @Test("Array lengths are read")
    func readsArrayLength() {
        let result = parse("uniform float g_Weights[8];")
        #expect(result.uniforms.first?.arrayLength == 8)
    }

    @Test("An array sized by a macro is declined rather than guessed at")
    func declinesSymbolicArraySize() {
        let result = parse("uniform float g_Weights[SAMPLE_COUNT];")
        #expect(result.uniforms.isEmpty)
        #expect(!result.diagnostics.isEmpty)
    }

    @Test("Precision and layout qualifiers are ignored")
    func ignoresQualifiers() {
        let result = parse("""
        uniform highp float g_A;
        layout(binding = 3) uniform sampler2D g_B;
        """)
        #expect(result.uniforms.map(\.name) == ["g_A", "g_B"])
        #expect(result.uniforms[1].type == .sampler2D)
    }

    @Test("A commented-out uniform is not a uniform")
    func ignoresCommentedDeclarations() {
        let result = parse("""
        /*
        uniform vec4 g_Disabled;
        */
        uniform vec4 g_Live;
        """)
        #expect(result.uniforms.map(\.name) == ["g_Live"])
    }

    @Test("A uniform inside a block is left where it is")
    func ignoresBlockMembers() {
        // Hoisting one out of an existing block would declare it twice.
        let result = parse("""
        uniform Existing {
            vec4 inner;
        };
        uniform vec4 g_Outer;
        """)
        #expect(result.uniforms.map(\.name) == ["g_Outer"])
    }

    @Test("Samplers and block members are separated")
    func separatesOpaqueTypes() {
        let result = parse("""
        uniform sampler2D g_Texture0;
        uniform vec4 g_Tint;
        uniform samplerCube g_Env;
        """)
        #expect(result.samplers.map(\.name) == ["g_Texture0", "g_Env"])
        #expect(result.blockMembers.map(\.name) == ["g_Tint"])
    }

    @Test("A duplicate declaration is dropped so the block declares it once")
    func dropsDuplicates() {
        // Two expansions of the same include produce this, and a block with the member twice
        // does not compile.
        let result = parse("""
        uniform vec4 g_Tint;
        uniform vec4 g_Tint;
        """)
        #expect(result.uniforms.count == 1)
    }

    @Test("Reversed range bounds are ordered")
    func ordersRange() {
        let result = parse(#"uniform float g_A; // {"range":[2,0]}"#)
        #expect(result.uniforms.first?.range == 0...2)
    }

    @Test("An unreadable annotation still yields the uniform")
    func keepsUniformWithBadAnnotation() {
        // Dropping it would shift every offset after it; losing only its editability does not.
        let result = parse("uniform vec4 g_Tint; // {this is not json")
        #expect(result.uniforms.count == 1)
        #expect(result.uniforms.first?.material == nil)
        #expect(result.diagnostics.contains { $0.kind == .malformedUniformMetadata })
    }


    @Test("A three-component colour default in a vec4 is opaque, not transparent")
    func colourDefaultIsOpaque() {
        // Shipped shaders write `"default":"1 1 1"` on a vec4 tint all the time. Padding the
        // fourth component with 0 makes the layer vanish, which reads as a broken renderer.
        let result = parse(#"uniform vec4 g_Tint; // {"default":"0.5 0.25 0","type":"color"}"#)
        #expect(result.uniforms.first?.defaultValue == .vector([0.5, 0.25, 0, 1]))
    }

    @Test("A vec4 that is not a colour still pads with zero")
    func nonColourDefaultPadsWithZero() {
        let result = parse(#"uniform vec4 g_Params; // {"default":"1 2 3"}"#)
        #expect(result.uniforms.first?.defaultValue == .vector([1, 2, 3, 0]))
    }

    @Test("A sampler's default is its texture path")
    func readsTextureDefault() {
        let result = parse(#"uniform sampler2D g_Noise; // {"default":"materials/noise.tex"}"#)
        #expect(result.uniforms.first?.defaultValue == .texture("materials/noise.tex"))
    }
}

@Suite("UniformBlockLayout")
struct UniformBlockLayoutTests {

    private func layout(_ declarations: [(String, ShaderUniformType, Int?)]) -> UniformBlockLayout {
        UniformBlockLayout.std140(for: declarations.map {
            ShaderUniformDeclaration(name: $0.0, type: $0.1, arrayLength: $0.2)
        })
    }

    @Test("A vec3 aligns to 16 but occupies 12, so a float packs into its tail")
    func packsScalarAfterVec3() {
        // Getting this wrong is the classic std140 mistake and would misplace every member
        // after the vec3. These offsets are cross-checked against the translator in
        // BackendTests.
        let result = layout([
            ("g_Tint", .vec4, nil),
            ("g_Speed", .float, nil),
            ("g_Direction", .vec3, nil),
            ("g_Time", .float, nil),
            ("g_MVP", .mat4, nil),
        ])
        #expect(result.members.map(\.offset) == [0, 16, 32, 44, 48])
        #expect(result.size == 112)
    }

    @Test("Array elements are spaced 16 bytes apart whatever their type")
    func roundsArrayStrideToVec4() {
        // An array of floats is not tightly packed in std140; assuming it is reads every
        // element but the first from the wrong place.
        let result = layout([("g_Weights", .float, 4)])
        #expect(result.members.first?.stride == 16)
        #expect(result.members.first?.size == 64)
        #expect(result.size == 64)
    }

    @Test("Mixed arrays, matrices and scalars land where std140 says")
    func matchesPublishedRules() {
        let result = layout([
            ("g_Weights", .float, 4),
            ("g_Offsets", .vec2, 3),
            ("g_Rotation", .mat3, nil),
            ("g_Enabled", .bool, nil),
            ("g_Colors", .vec3, 2),
            ("g_Count", .int, nil),
        ])
        #expect(result.members.map(\.offset) == [0, 64, 112, 160, 176, 208])
        #expect(result.size == 224)
    }

    @Test("A mat3 is three padded columns, not nine floats")
    func padsMatrixColumns() {
        let result = layout([("g_Rotation", .mat3, nil)])
        #expect(result.members.first?.size == 48)
    }

    @Test("Samplers are not block members")
    func excludesOpaqueTypes() {
        let result = layout([("g_Texture0", .sampler2D, nil), ("g_Tint", .vec4, nil)])
        #expect(result.members.map(\.name) == ["g_Tint"])
        #expect(result.members.first?.offset == 0)
    }

    @Test("No members means no block")
    func emptyLayout() {
        let result = layout([])
        #expect(result.isEmpty)
        #expect(result.size == 0)
    }

    @Test("Declaration order is preserved")
    func preservesOrder() {
        // The emitted GLSL declares members in this order, so sorting here would silently
        // describe a different block than the one compiled.
        let result = layout([("z", .float, nil), ("a", .float, nil), ("m", .float, nil)])
        #expect(result.members.map(\.name) == ["z", "a", "m"])
    }
}
