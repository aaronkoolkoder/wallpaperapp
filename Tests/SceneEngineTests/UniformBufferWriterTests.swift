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
        unannotated: Bool = false
    ) -> ShaderUniformDeclaration {
        ShaderUniformDeclaration(
            name: name, type: type, arrayLength: arrayLength, material: material,
            defaultValue: defaultValue, isUnannotated: unannotated
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
}
