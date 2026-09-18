import Foundation
import Testing
@testable import ShaderTranspiler

@Suite("ShaderPreprocessor")
struct ShaderPreprocessorTests {

    private let preprocessor = ShaderPreprocessor()

    private func run(
        _ text: String,
        stage: ShaderStage = .fragment,
        files: [String: String] = [:],
        combos: [String: Int] = [:]
    ) throws -> PreprocessedShader {
        try preprocessor.preprocess(
            ShaderSource(name: "test.\(stage.fileExtension)", stage: stage, text: text),
            provider: InMemoryShaderFileProvider(files),
            comboOverrides: combos
        )
    }

    // MARK: Version

    @Test("The emitted shader always declares 450 on its first line")
    func pinsVersion() throws {
        // glslang is told to target Vulkan, which needs a core version; a shader that declared
        // an older one would contradict the rewrite the body has already had.
        let result = try run("#version 120\nvoid main() {}")
        #expect(result.glsl.hasPrefix("#version 450\n"))
        #expect(!result.glsl.contains("#version 120"))
    }

    @Test("A missing version is noted rather than passed over")
    func reportsMissingVersion() throws {
        let result = try run("void main() {}")
        #expect(result.diagnostics.contains { $0.kind == .missingVersionDirective })
    }

    // MARK: Uniforms

    @Test("Free-floating uniforms are gathered into a block")
    func gathersUniforms() throws {
        // Vulkan forbids non-opaque uniforms outside a block and glslang rejects them
        // outright, so this is what makes a Wallpaper Engine shader compile at all.
        let result = try run("""
        uniform vec4 g_Tint;
        uniform float g_Speed;
        void main() { }
        """)

        #expect(result.glsl.contains("layout(std140) uniform DioramaUniforms {"))
        #expect(result.glsl.contains("    vec4 g_Tint;"))
        #expect(result.glsl.contains("    float g_Speed;"))
        // No instance name, so the body still refers to them unqualified.
        #expect(result.glsl.contains("\n};"))
        #expect(result.layout.members.map(\.name) == ["g_Tint", "g_Speed"])
    }

    @Test("Samplers stay where they were declared")
    func leavesSamplersInPlace() throws {
        let result = try run("""
        uniform sampler2D g_Texture0;
        uniform vec4 g_Tint;
        void main() { }
        """)
        #expect(result.glsl.contains("uniform sampler2D g_Texture0;"))
        #expect(result.samplers.map(\.name) == ["g_Texture0"])
    }

    @Test("No uniforms means no empty block")
    func omitsEmptyBlock() throws {
        // An empty uniform block is not valid GLSL.
        let result = try run("void main() {}")
        #expect(!result.glsl.contains("DioramaUniforms"))
    }

    @Test("Array uniforms keep their length in the block")
    func preservesArrayLength() throws {
        let result = try run("uniform float g_Weights[4];\nvoid main() {}")
        #expect(result.glsl.contains("float g_Weights[4];"))
    }

    // MARK: Legacy syntax

    @Test("varying becomes out in a vertex shader and in in a fragment shader")
    func rewritesVarying() throws {
        // Removed from core GLSL in 4.20; glslang errors rather than warning.
        let fragment = try run("varying vec2 v_TexCoord;\nvoid main() {}")
        #expect(fragment.glsl.contains("in vec2 v_TexCoord;"))
        #expect(!fragment.glsl.contains("varying"))

        let vertex = try run("varying vec2 v_TexCoord;\nvoid main() {}", stage: .vertex)
        #expect(vertex.glsl.contains("out vec2 v_TexCoord;"))
    }

    @Test("attribute becomes in")
    func rewritesAttribute() throws {
        let result = try run("attribute vec3 a_Position;\nvoid main() {}", stage: .vertex)
        #expect(result.glsl.contains("in vec3 a_Position;"))
    }

    @Test("Legacy qualifiers are reported once, not once per line")
    func reportsLegacyQualifiersOnce() throws {
        let result = try run("""
        varying vec2 a;
        varying vec2 b;
        varying vec2 c;
        void main() {}
        """)
        #expect(result.diagnostics.filter { $0.kind == .legacyQualifiers }.count == 1)
    }

    @Test("Removed texture builtins are rewritten")
    func rewritesTextureBuiltins() throws {
        let result = try run("""
        uniform sampler2D s;
        void main() { vec4 a = texture2D(s, vec2(0)); vec4 b = textureCube(s, vec3(0)); }
        """)
        #expect(result.glsl.contains("texture(s, vec2(0))"))
        #expect(result.glsl.contains("texture(s, vec3(0))"))
        #expect(!result.glsl.contains("texture2D("))
    }

    @Test("texture2DLod is not half-rewritten by the texture2D rule")
    func rewritesWholeTokens() throws {
        // Substring replacement would turn this into `textureLodLod` or `textureLod` with the
        // wrong argument count, depending on rule order. Token-wise replacement cannot.
        let result = try run("""
        uniform sampler2D s;
        void main() { vec4 a = texture2DLod(s, vec2(0), 1.0); }
        """)
        #expect(result.glsl.contains("textureLod(s, vec2(0), 1.0)"))
        #expect(!result.glsl.contains("texture2DLod"))
        #expect(!result.glsl.contains("textureLodLod"))
    }

    @Test("A struct member named like a builtin is left alone")
    func skipsMemberAccess() throws {
        let result = try run("void main() { float x = state.texture2D; }")
        #expect(result.glsl.contains("state.texture2D"))
    }

    @Test("gl_FragColor becomes a declared output")
    func rewritesFragmentOutput() throws {
        let result = try run("void main() { gl_FragColor = vec4(1.0); }")
        #expect(result.glsl.contains("layout(location = 0) out vec4 \(ShaderPreprocessor.fragmentOutputName);"))
        #expect(result.glsl.contains("\(ShaderPreprocessor.fragmentOutputName) = vec4(1.0);"))
        #expect(!result.glsl.contains("gl_FragColor"))
    }

    @Test("gl_FragData[0] becomes the same output")
    func rewritesFragData() throws {
        let result = try run("void main() { gl_FragData[0] = vec4(1.0); }")
        #expect(result.glsl.contains("\(ShaderPreprocessor.fragmentOutputName) = vec4(1.0);"))
    }

    @Test("A second render target is reported as unsupported")
    func reportsMultipleRenderTargets() throws {
        let result = try run("void main() { gl_FragData[1] = vec4(1.0); }")
        #expect(result.diagnostics.contains { $0.severity == .unsupported })
    }

    @Test("The output is declared only when the legacy name is used")
    func omitsUnusedOutput() throws {
        // A shader that already declares its own output would otherwise get two at location 0.
        let result = try run("out vec4 myColor;\nvoid main() { myColor = vec4(1.0); }")
        #expect(!result.glsl.contains(ShaderPreprocessor.fragmentOutputName))
    }

    @Test("A vertex shader never gets a fragment output")
    func noFragmentOutputInVertex() throws {
        let result = try run("void main() { gl_Position = vec4(1.0); }", stage: .vertex)
        #expect(!result.glsl.contains(ShaderPreprocessor.fragmentOutputName))
    }

    // MARK: Combos

    @Test("Declared combos are defined at their defaults")
    func injectsComboDefaults() throws {
        let result = try run(#"""
        // [COMBO] {"combo":"BLOOM","default":1}
        // [COMBO] {"combo":"HDR","default":0}
        void main() {}
        """#)
        #expect(result.glsl.contains("#define BLOOM 1"))
        #expect(result.glsl.contains("#define HDR 0"))
        #expect(result.comboValues == ["BLOOM": 1, "HDR": 0])
    }

    @Test("An override replaces the default")
    func appliesComboOverrides() throws {
        let result = try run(#"""
        // [COMBO] {"combo":"BLOOM","default":1}
        void main() {}
        """#, combos: ["BLOOM": 3])
        #expect(result.glsl.contains("#define BLOOM 3"))
    }

    @Test("Setting a combo the shader does not declare is reported, not injected")
    func reportsUndeclaredCombo() throws {
        // Defining a macro nothing reads would look like it worked.
        let result = try run("void main() {}", combos: ["MISSING": 1])
        #expect(!result.glsl.contains("#define MISSING"))
        #expect(result.diagnostics.contains { $0.kind == .undeclaredCombo })
    }

    @Test("A combo the shader defines itself is not redefined")
    func avoidsComboMacroConflict() throws {
        // Redefining a macro with a different value is a hard preprocessor error, so injecting
        // ours would take the whole shader down rather than lose one property.
        let result = try run(#"""
        // [COMBO] {"combo":"BLOOM","default":1}
        #define BLOOM 0
        void main() {}
        """#)
        #expect(!result.glsl.contains("#define BLOOM 1"))
        #expect(result.diagnostics.contains { $0.kind == .comboMacroConflict })
    }

    // MARK: Includes

    @Test("Includes are expanded before anything else is parsed")
    func expandsIncludes() throws {
        let result = try run(
            "#include \"common.h\"\nvoid main() {}",
            files: ["common.h": "uniform vec4 g_Shared;"]
        )
        #expect(result.layout.members.map(\.name) == ["g_Shared"])
        #expect(result.includedFiles == ["common.h"])
    }

    @Test("A compiler error can be traced back to the file the author wrote")
    func mapsLinesBackToSource() throws {
        // Without this a glslang error names a line in a file that does not exist, because the
        // prologue shifted everything and includes were flattened into one buffer.
        let result = try run(
            "#include \"common.h\"\nvoid main() {}",
            files: ["common.h": "// one\n// two\nuniform vec4 g_Shared;"]
        )

        let firstBodyLine = result.prologueLineCount + 1
        #expect(result.origin(ofEmittedLine: firstBodyLine)?.file == "common.h")
        #expect(result.origin(ofEmittedLine: firstBodyLine)?.line == 1)
        // A prologue line came from nowhere in particular and says so.
        #expect(result.origin(ofEmittedLine: 1) == nil)
    }

    @Test("Every body line maps to exactly one source line")
    func preservesLineCount() throws {
        // The mapping is positional, so a rewrite that added or dropped a line would misreport
        // every error after it.
        let body = "uniform vec4 g_A;\nvarying vec2 v;\n#version 120\nvoid main() {}"
        let result = try run(body)
        let emitted = result.glsl.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(emitted.count - result.prologueLineCount - 1 == result.lineMap.count)
    }

    // MARK: Varyings

    @Test("Both stages agree on where each varying lives")
    func matchesVaryingLocationsAcrossStages() throws {
        // The stages compile as separate programs, so nothing else makes them agree. When the
        // vertex shader declares one the fragment shader does not, independent numbering would
        // have the fragment shader read whichever varying happened to land in that slot.
        let (vertex, fragment) = try preprocessor.preprocessPair(
            vertex: ShaderSource(name: "a.vert", stage: .vertex, text: """
            attribute vec3 a_Position;
            varying vec2 v_TexCoord;
            varying vec3 v_Normal;
            varying vec4 v_Color;
            void main() {}
            """),
            fragment: ShaderSource(name: "a.frag", stage: .fragment, text: """
            varying vec4 v_Color;
            varying vec2 v_TexCoord;
            void main() {}
            """),
            provider: InMemoryShaderFileProvider([:])
        )

        func location(of name: String, in shader: PreprocessedShader) -> Int? {
            for line in shader.glsl.split(separator: "\n") where line.hasSuffix(" \(name);") {
                if let match = line.firstMatch(of: /location = (\d+)/) { return Int(match.1) }
            }
            return nil
        }

        #expect(location(of: "v_TexCoord", in: vertex) == location(of: "v_TexCoord", in: fragment))
        #expect(location(of: "v_Color", in: vertex) == location(of: "v_Color", in: fragment))
        #expect(location(of: "v_TexCoord", in: fragment) != location(of: "v_Color", in: fragment))
    }

    @Test("A vertex attribute gets no shared location")
    func skipsVertexAttributes() throws {
        // Attributes are bound through Metal's vertex descriptor and never reach the fragment
        // stage, so numbering them alongside varyings would waste locations and confuse both.
        let result = try run("attribute vec3 a_Position;\nvoid main() {}", stage: .vertex)
        #expect(result.glsl.contains("in vec3 a_Position;"))
        #expect(!result.varyings.contains("a_Position"))
    }

    @Test("An author-assigned location is kept and not handed out again")
    func reservesExplicitLocations() throws {
        let result = try run("""
        layout(location = 0) in vec2 v_Explicit;
        varying vec3 v_Auto;
        void main() {}
        """)
        #expect(result.glsl.contains("layout(location = 0) in vec2 v_Explicit;"))
        #expect(!result.glsl.contains("layout(location = 0) in vec3 v_Auto;"))
    }

    @Test("A parameter qualifier is not a varying declaration")
    func ignoresParameterQualifiers() throws {
        // `in` and `out` are also parameter qualifiers; rewriting a function signature as a
        // declaration would produce something that does not compile.
        let result = try run("""
        float scale(in vec3 v, out float extra) { extra = 1.0; return v.x; }
        void main() {}
        """)
        #expect(result.glsl.contains("float scale(in vec3 v, out float extra)"))
        #expect(result.varyings.isEmpty)
    }

    // MARK: Hashing

    @Test("The content hash changes when the combo values do")
    func hashCoversCombos() throws {
        // The hash is the cache key. If it ignored combos, every variant of a shader would be
        // served whichever one was compiled first.
        let source = #"""
        // [COMBO] {"combo":"BLOOM","default":0}
        void main() {}
        """#
        let off = try run(source, combos: ["BLOOM": 0])
        let on = try run(source, combos: ["BLOOM": 1])
        #expect(off.sourceHash != on.sourceHash)
    }

    @Test("The same input twice gives the same hash")
    func hashIsStable() throws {
        let source = "uniform vec4 g_A;\nvarying vec2 v;\nvoid main() { gl_FragColor = g_A; }"
        #expect(try run(source).sourceHash == (try run(source).sourceHash))
    }

    // MARK: Failure

    @Test("A missing include is an error, not a silently broken shader")
    func reportsMissingInclude() {
        #expect(throws: ShaderPreprocessorError.self) {
            try run("#include \"nope.h\"\nvoid main() {}")
        }
    }
}
