import Foundation
import ShaderTranspiler
import Testing
import WEFormat
import simd
@testable import SceneEngine

@Suite("UniformBufferWriter")
struct UniformBufferWriterTests {

    private func declaration(
        _ name: String,
        _ type: ShaderUniformType,
        arrayLength: Int? = nil,
        material: String? = nil,
        defaultValue: ShaderUniformValue? = nil,
        editor: ShaderUniformEditor? = nil,
        unannotated: Bool = false
    ) -> ShaderUniformDeclaration {
        ShaderUniformDeclaration(
            name: name, type: type, arrayLength: arrayLength, material: material,
            defaultValue: defaultValue, editor: editor, isUnannotated: unannotated
        )
    }

    private func floats(_ result: UniformBufferWriter.Result, at offset: Int, count: Int) -> [Float] {
        (0 ..< count).map { index in
            let at = offset + index * 4
            let bits = result.bytes[at ..< at + 4].enumerated().reduce(UInt32(0)) { total, pair in
                total | (UInt32(pair.element) << (8 * UInt32(pair.offset)))
            }
            return Float(bitPattern: bits)
        }
    }

    @Test("An annotation's default is used when nothing else supplies a value")
    func writesDefaults() {
        let declarations = [declaration("g_Tint", .vec4, defaultValue: .vector([1, 0.5, 0.25, 1]))]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 4) == [1, 0.5, 0.25, 1])
    }

    @Test("A material constant beats the annotation's default")
    func constantsBeatDefaults() {
        // The material is the wallpaper author's decision; the default is the shader author's.
        let declarations = [declaration("g_Tint", .vec4, defaultValue: .vector([1, 1, 1, 1]))]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            constants: ["g_Tint": .string("0 0.25 0.5 1")],
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 4) == [0, 0.25, 0.5, 1])
    }

    @Test("A constant keyed by the material name is found too")
    func constantsMatchMaterialKey() {
        // Shipped content keys these both ways.
        let declarations = [declaration("g_Tint", .vec4, material: "tint")]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            constants: ["tint": .string("1 0 0 1")],
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 4) == [1, 0, 0, 1])
    }

    @Test("Engine values beat everything")
    func engineValuesWin() {
        // A material cannot meaningfully override the projection matrix, and one that tries
        // would put the layer somewhere the scene never asked for.
        let declarations = [declaration("g_Time", .float, unannotated: true)]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            constants: ["g_Time": .number(99)],
            engine: EngineUniforms(time: 12.5)
        )
        #expect(floats(result, at: 0, count: 1) == [12.5])
    }

    @Test("The projection matrix is written column-major")
    func writesMatrixColumnMajor() {
        // Row-major would transpose every layer's placement, which looks like a scene-graph bug.
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(10, 20, 30, 1)
        let declarations = [declaration("g_ModelViewProjection", .mat4, unannotated: true)]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            engine: EngineUniforms(modelViewProjection: matrix)
        )
        // Translation lives in the fourth column, at floats 12 through 15.
        #expect(floats(result, at: 0, count: 16)[12...14] == [10, 20, 30])
    }

    @Test("A mat3's columns are padded to 16 bytes each")
    func padsMatrixColumns() {
        // std140 spaces a mat3's columns like vec4s. Writing nine floats contiguously would
        // scramble the second and third columns.
        let declarations = [declaration("g_Rotation", .mat3, defaultValue: .vector([1, 2, 3, 4, 5, 6, 7, 8, 9]))]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 3) == [1, 2, 3])
        #expect(floats(result, at: 16, count: 3) == [4, 5, 6])
        #expect(floats(result, at: 32, count: 3) == [7, 8, 9])
    }

    @Test("Array elements are written at their stride, not packed")
    func writesArraysAtStride() {
        // An array of floats is spaced 16 bytes apart in std140; packing them would leave every
        // element but the first reading whatever was next to it.
        let declarations = [declaration("g_Weights", .float, arrayLength: 3, defaultValue: .vector([0.25, 0.5, 0.75]))]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 1) == [0.25])
        #expect(floats(result, at: 16, count: 1) == [0.5])
        #expect(floats(result, at: 32, count: 1) == [0.75])
    }

    @Test("A uniform nothing supplies is left zeroed rather than filled with rubbish")
    func zeroFillsUnsupplied() {
        let declarations = [declaration("g_Unknown", .vec4)]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            engine: EngineUniforms()
        )
        #expect(result.bytes.allSatisfy { $0 == 0 })
    }

    @Test("A reserved name the app does not provide is reported")
    func reportsUnsuppliedEngineUniforms() {
        // A shader driven by an unsupplied uniform renders a still frame and looks broken
        // rather than unsupported, so the compatibility report has to say so.
        let declarations = [declaration("g_SomethingReserved", .vec4, unannotated: true)]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            engine: EngineUniforms()
        )
        #expect(result.unsuppliedEngineUniforms == ["g_SomethingReserved"])
    }

    @Test("An annotated uniform is not mistaken for an engine one")
    func annotatedUniformsAreNotReported() {
        let declarations = [declaration("g_Tint", .vec4, material: "tint")]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            engine: EngineUniforms()
        )
        #expect(result.unsuppliedEngineUniforms.isEmpty)
    }

    @Test("Texture resolutions are matched to their slot")
    func writesTextureResolution() {
        let declarations = [declaration("g_Texture1Resolution", .vec4, unannotated: true)]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            engine: EngineUniforms(textureResolutions: [
                SIMD4(64, 64, 1.0 / 64, 1.0 / 64),
                SIMD4(256, 128, 1.0 / 256, 1.0 / 128),
            ])
        )
        #expect(floats(result, at: 0, count: 2) == [256, 128])
    }

    @Test("Several spellings of the matrix reach the same value")
    func acceptsMatrixSpellings() {
        // Shipped content uses all of these, and honouring only one leaves the others at zero,
        // which collapses the layer to a point.
        let engine = EngineUniforms(modelViewProjection: matrix_identity_float4x4)
        #expect(engine.value(for: "g_ModelViewProjection") != nil)
        #expect(engine.value(for: "g_ModelViewProjectionMatrix") != nil)
        #expect(engine.value(for: "g_Time") != nil)
        #expect(engine.value(for: "g_NotAThing") == nil)
    }

    @Test("Reused storage does not leak the previous draw's values")
    func reusedStorageIsCleared() {
        // The renderer keeps one scratch array across every material it draws, sized to the
        // largest layout it has seen. Without zeroing, a shader with a smaller block would read
        // whatever the previous, larger one left behind — a stale value that changes with draw
        // order and would be miserable to reproduce.
        var scratch: [UInt8] = []

        let large = [declaration("g_A", .vec4, defaultValue: .vector([1, 2, 3, 4])),
                     declaration("g_B", .vec4, defaultValue: .vector([5, 6, 7, 8]))]
        UniformBufferWriter.fill(
            into: &scratch, layout: UniformBlockLayout.std140(for: large),
            declarations: large, engine: EngineUniforms()
        )

        let small = [declaration("g_C", .vec4)]
        let smallLayout = UniformBlockLayout.std140(for: small)
        UniformBufferWriter.fill(
            into: &scratch, layout: smallLayout, declarations: small, engine: EngineUniforms()
        )

        #expect(scratch[0 ..< smallLayout.size].allSatisfy { $0 == 0 })
    }

    @Test("Storage grows to the largest layout and is reused after")
    func storageGrowsOnce() {
        var scratch: [UInt8] = []
        let small = [declaration("g_A", .float, defaultValue: .scalar(1))]
        UniformBufferWriter.fill(
            into: &scratch, layout: UniformBlockLayout.std140(for: small),
            declarations: small, engine: EngineUniforms()
        )
        let firstSize = scratch.count

        let large = [declaration("g_M", .mat4, defaultValue: .vector(Array(repeating: 1, count: 16)))]
        UniformBufferWriter.fill(
            into: &scratch, layout: UniformBlockLayout.std140(for: large),
            declarations: large, engine: EngineUniforms()
        )
        #expect(scratch.count > firstSize)

        let grownSize = scratch.count
        UniformBufferWriter.fill(
            into: &scratch, layout: UniformBlockLayout.std140(for: small),
            declarations: small, engine: EngineUniforms()
        )
        // Never shrinks, so drawing a small material after a large one does not reallocate.
        #expect(scratch.count == grownSize)
    }

    @Test("A short value does not write past its member")
    func doesNotOverrun() {
        // A malformed constant is common; writing past the member would corrupt the next one.
        let declarations = [
            declaration("g_A", .vec4, defaultValue: .vector([1, 2, 3, 4, 5, 6, 7, 8])),
            declaration("g_B", .vec4, defaultValue: .vector([9, 9, 9, 9])),
        ]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 4) == [1, 2, 3, 4])
        #expect(floats(result, at: 16, count: 4) == [9, 9, 9, 9])
    }

    @Test("A user setting beats the material's baked constant")
    func overridesBeatConstants() {
        // The user changed it deliberately and just now; the material's value is what the
        // wallpaper's author baked in.
        let declarations = [declaration("g_Tint", .vec4, material: "tint")]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            constants: ["tint": .string("1 1 1 1")],
            overrides: ["tint": .string("0 1 0 1")],
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 4) == [0, 1, 0, 1])
    }

    @Test("A user setting is matched by the property key the annotation names")
    func overridesMatchMaterialKey() {
        // `project.json` keys its properties by name, and a uniform's annotation names the key
        // it follows. That connection is what lets a slider labelled Speed drive `g_Speed`.
        let declarations = [declaration("g_Speed", .float, material: "speed")]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            overrides: ["speed": .number(0.25)],
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 1) == [0.25])
    }

    @Test("A uniform with no annotation can still be set by its own name")
    func overridesMatchUniformName() {
        // A wallpaper whose uniform carries no annotation has no property key to match on.
        let declarations = [declaration("g_Speed", .float)]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            overrides: ["g_Speed": .number(2)],
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 1) == [2])
    }

    @Test("A user setting does not beat an engine value")
    func engineBeatsOverrides() {
        // There is no sensible user setting for the projection matrix, and honouring one would
        // put the layer somewhere the scene never asked for.
        let declarations = [declaration("g_Time", .float, unannotated: true)]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            overrides: ["g_Time": .number(99)],
            engine: EngineUniforms(time: 3)
        )
        #expect(floats(result, at: 0, count: 1) == [3])
    }

    @Test("Clearing a setting falls back to the material, then the annotation")
    func clearedOverrideFallsBack() {
        let declarations = [
            declaration("g_A", .float, material: "a", defaultValue: .scalar(1)),
            declaration("g_B", .float, material: "b", defaultValue: .scalar(1)),
        ]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            constants: ["a": .number(5)],
            overrides: [:],
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 1) == [5])
        #expect(floats(result, at: 4, count: 1) == [1])
    }

    @Test("A three-component colour in a vec4 gets alpha 1, not 0")
    func colourAlphaDefaultsToOpaque() {
        // Wallpaper Engine writes colours as three components, which is what a `color` property
        // holds and what a colour picker produces. Padding the fourth with 0 multiplies the
        // layer away entirely, and an invisible layer reads as a broken renderer rather than as
        // a colour with no alpha.
        let declarations = [declaration("g_Tint", .vec4, material: "tint", editor: .color)]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            overrides: ["tint": .string("1 0 0")],
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 4) == [1, 0, 0, 1])
    }

    @Test("An explicit alpha is left alone")
    func explicitAlphaSurvives() {
        let declarations = [declaration("g_Tint", .vec4, material: "tint", editor: .color)]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            overrides: ["tint": .string("1 0 0 0.5")],
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 4) == [1, 0, 0, 0.5])
    }

    @Test("A vec4 that is not a colour is still padded with zero")
    func nonColourPadsWithZero() {
        // A direction or a set of weights has no alpha, and inventing a 1 there would be as
        // wrong as a transparent tint.
        let declarations = [declaration("g_Params", .vec4, material: "params")]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            overrides: ["params": .string("1 2 3")],
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 4) == [1, 2, 3, 0])
    }

    @Test("A vec3 colour is unaffected")
    func vec3ColourUnchanged() {
        let declarations = [declaration("g_Tint", .vec3, material: "tint", editor: .color)]
        let result = UniformBufferWriter.fill(
            layout: UniformBlockLayout.std140(for: declarations),
            declarations: declarations,
            overrides: ["tint": .string("1 0 0")],
            engine: EngineUniforms()
        )
        #expect(floats(result, at: 0, count: 3) == [1, 0, 0])
    }

    /// The render path fills from a plan worked out when the shader compiled, rather than by
    /// matching names per draw. It has to put exactly the same bytes in the buffer: the plan is
    /// a way of not redoing the decision, not a different decision.
    @Test("Filling from a plan writes the same buffer as filling by name")
    func planMatchesTheNameDrivenFill() {
        let declarations = [
            declaration("g_ModelViewProjection", .mat4),
            declaration("g_Time", .float),
            declaration("g_Texture0Resolution", .vec4),
            declaration("g_Tint", .vec4, material: "tint", defaultValue: .vector([1, 1, 1, 1]),
                        editor: .color),
            declaration("g_Speed", .float, material: "speed", defaultValue: .scalar(0.5)),
            declaration("g_Bands", .float, arrayLength: 16),
            declaration("g_Unknown", .vec2, unannotated: true),
        ]
        let layout = UniformBlockLayout.std140(for: declarations)
        var engine = EngineUniforms(
            time: 12.5, dayTime: 0.25, pointerPosition: SIMD2(0.2, -0.4),
            textureResolutions: [SIMD4(1920, 1080, 1900, 1000)]
        )
        engine.modelViewProjection = simd_float4x4(diagonal: SIMD4(2, 3, 4, 1))
        let constants: [String: DynamicValue] = ["g_Bands": .number(3)]
        let overrides: [String: DynamicValue] = ["tint": .string("1 0 0"), "speed": .number(2)]

        let byName = UniformBufferWriter.fill(
            layout: layout, declarations: declarations,
            constants: constants, overrides: overrides, engine: engine
        )

        var bytes: [UInt8] = []
        var scratch: [Float] = []
        var unsupplied: [String] = []
        UniformBufferWriter.fill(
            into: &bytes, plan: UniformPlan(layout: layout, declarations: declarations),
            constants: constants, overrides: overrides, engine: engine,
            scratch: &scratch, unsupplied: &unsupplied
        )

        #expect(Array(bytes.prefix(layout.size)) == Array(byName.bytes.prefix(layout.size)))
        #expect(unsupplied == byName.unsuppliedEngineUniforms)
        #expect(unsupplied == ["g_Unknown"], "a reserved name nothing supplies is still reported")
        // A colour written as three components still gets its alpha completed, or the layer
        // it tints multiplies away to nothing.
        #expect(floats(byName, at: layout.members.first { $0.name == "g_Tint" }!.offset, count: 4)
                == [1, 0, 0, 1])
    }

    /// Reading an engine value used to return a fresh array, which on the frame path is an
    /// allocation per uniform per draw. PLAN.md §6.2 rules those out.
    @Test("An engine value is read into caller-owned storage, which is reused")
    func engineValuesFillCallerStorage() {
        var engine = EngineUniforms(time: 7, screenSize: SIMD2(800, 600))
        engine.modelViewProjection = simd_float4x4(diagonal: SIMD4(1, 2, 3, 4))
        var scratch: [Float] = []

        #expect(engine.read(.time, into: &scratch) == 1)
        #expect(scratch[0] == 7)
        #expect(engine.read(.modelViewProjection, into: &scratch) == 16)
        #expect(Array(scratch.prefix(6)) == [1, 0, 0, 0, 0, 2])
        #expect(engine.read(.texelSize, into: &scratch) == 2)
        #expect(abs(scratch[0] - 1.0 / 800) < 1e-6)
        // Storage grew once and is reused for every read after.
        #expect(scratch.count >= 16)
        // Nothing to supply stays nothing to supply, rather than reading as zeros.
        #expect(engine.read(.audioSpectrumLeft, into: &scratch) == nil)
        #expect(engine.read(.textureResolution(3), into: &scratch) == nil)
    }

    @Test("A name that means no engine value resolves to no slot")
    func slotsResolveByName() {
        #expect(EngineUniforms.Slot.named("g_ModelViewProjectionMatrix") == .modelViewProjection)
        #expect(EngineUniforms.Slot.named("g_GlobalTime") == .time)
        #expect(EngineUniforms.Slot.named("g_Texture3Resolution") == .textureResolution(3))
        #expect(EngineUniforms.Slot.named("g_Tint") == nil)
    }
}
