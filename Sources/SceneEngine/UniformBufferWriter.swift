import Foundation
import ShaderTranspiler
import WEFormat
import simd

/// The values Wallpaper Engine supplies to every shader, rather than the wallpaper's author.
///
/// Shaders take these as ordinary uniforms with reserved `g_` names, so nothing in the material
/// declares them and a shader that reads one gets whatever the app puts here. Anything not
/// listed is reported rather than quietly left at zero — a shader driven by an unsupplied
/// `g_Time` renders a still frame and looks broken rather than unsupported.
public struct EngineUniforms: Sendable {
    public var modelViewProjection: simd_float4x4
    /// Seconds since the wallpaper started.
    public var time: Float
    /// Time of day as a fraction of 24 hours, which day/night shaders branch on.
    public var dayTime: Float
    /// Pointer position in normalised screen coordinates.
    public var pointerPosition: SIMD2<Float>
    /// Output size in pixels.
    public var screenSize: SIMD2<Float>
    /// Per texture slot: the allocated texture's width and height in `xy`, and the image
    /// inside it in `zw`. The stock shaders are what pin this down — `foliagesway.vert` takes
    /// `z / w` as the image's aspect ratio, and the mask path rescales a UV by `z / x`, which
    /// only means anything if `xy` is the allocation and `zw` the content. With no padding
    /// the two are equal.
    public var textureResolutions: [SIMD4<Float>]
    /// 16-band spectrum per channel, when audio reactivity is running.
    public var audioSpectrumLeft: [Float]
    public var audioSpectrumRight: [Float]

    public init(
        modelViewProjection: simd_float4x4 = matrix_identity_float4x4,
        time: Float = 0,
        dayTime: Float = 0,
        pointerPosition: SIMD2<Float> = .zero,
        screenSize: SIMD2<Float> = SIMD2(1920, 1080),
        textureResolutions: [SIMD4<Float>] = [],
        audioSpectrumLeft: [Float] = [],
        audioSpectrumRight: [Float] = []
    ) {
        self.modelViewProjection = modelViewProjection
        self.time = time
        self.dayTime = dayTime
        self.pointerPosition = pointerPosition
        self.screenSize = screenSize
        self.textureResolutions = textureResolutions
        self.audioSpectrumLeft = audioSpectrumLeft
        self.audioSpectrumRight = audioSpectrumRight
    }

    /// The value for a reserved name, or `nil` when the app does not supply it.
    ///
    /// Several spellings of the matrix are in use across shipped content, so all of the ones
    /// observed map to the same value rather than only the one this app happens to prefer.
    public func value(for name: String) -> [Float]? {
        switch name {
        case "g_ModelViewProjection", "g_ModelViewProjectionMatrix",
             "g_ModelViewProjectionMatrixInverse", "g_ViewProjectionMatrix":
            return Self.floats(of: modelViewProjection)
        case "g_Time", "g_AnimationTime", "g_GlobalTime":
            return [time]
        case "g_DayTime":
            return [dayTime]
        case "g_PointerPosition":
            return [pointerPosition.x, pointerPosition.y]
        case "g_Screen":
            return [screenSize.x, screenSize.y]
        case "g_TexelSize":
            return [1 / max(screenSize.x, 1), 1 / max(screenSize.y, 1)]
        case "g_TexelSizeHalf":
            return [0.5 / max(screenSize.x, 1), 0.5 / max(screenSize.y, 1)]
        case "g_AudioSpectrum16Left":
            return audioSpectrumLeft.isEmpty ? nil : audioSpectrumLeft
        case "g_AudioSpectrum16Right":
            return audioSpectrumRight.isEmpty ? nil : audioSpectrumRight
        default:
            // `g_Texture0Resolution` through `g_Texture7Resolution`.
            if let slot = Self.textureResolutionSlot(in: name) {
                guard slot < textureResolutions.count else { return nil }
                let resolution = textureResolutions[slot]
                return [resolution.x, resolution.y, resolution.z, resolution.w]
            }
            return nil
        }
    }

    static func textureResolutionSlot(in name: String) -> Int? {
        guard name.hasPrefix("g_Texture"), name.hasSuffix("Resolution") else { return nil }
        let digits = name.dropFirst("g_Texture".count).dropLast("Resolution".count)
        return Int(digits)
    }

    /// Column-major, which is how both GLSL and std140 store a matrix.
    static func floats(of matrix: simd_float4x4) -> [Float] {
        [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
            .flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
}

/// Fills a shader's constant buffer from four sources, in order of precedence.
///
/// The order is what makes a wallpaper look right and do what the user asked. The engine's own
/// values win, because a material cannot meaningfully override the projection matrix. Then the
/// user's setting, because they changed it deliberately and just now. Then the material's baked
/// constant, then the annotation's default. A uniform nothing supplies is left zeroed, which is
/// the same thing an unbound OpenGL uniform would read.
public enum UniformBufferWriter {

    /// What happened while filling a buffer, so the compatibility report can say which uniforms
    /// went unsupplied rather than leaving the wallpaper looking subtly wrong.
    public struct Result: Sendable {
        public var bytes: [UInt8]
        /// Reserved `g_` names the shader reads that this app does not provide.
        public var unsuppliedEngineUniforms: [String]
    }

    public static func fill(
        layout: UniformBlockLayout,
        declarations: [ShaderUniformDeclaration],
        constants: [String: DynamicValue] = [:],
        overrides: [String: DynamicValue] = [:],
        engine: EngineUniforms
    ) -> Result {
        var bytes: [UInt8] = []
        let unsupplied = fill(
            into: &bytes, layout: layout, declarations: declarations,
            constants: constants, overrides: overrides, engine: engine
        )
        return Result(bytes: bytes, unsuppliedEngineUniforms: unsupplied)
    }

    /// Fills reusable storage rather than returning a fresh array.
    ///
    /// This runs once per material draw per frame, so allocating here would be exactly the
    /// per-frame allocation PLAN.md §6.2 rules out. `bytes` is resized only when the layout
    /// grows, and zeroed every call so a uniform nothing supplies does not inherit the last
    /// draw's value.
    @discardableResult
    /// - Parameter overrides: the user's own settings, keyed as `project.json` keys them. A
    ///   uniform's annotation names the property key it follows, which is what connects a
    ///   slider labelled "Speed" to a uniform called `g_Speed`.
    public static func fill(
        into bytes: inout [UInt8],
        layout: UniformBlockLayout,
        declarations: [ShaderUniformDeclaration],
        constants: [String: DynamicValue] = [:],
        overrides: [String: DynamicValue] = [:],
        engine: EngineUniforms
    ) -> [String] {
        if bytes.count < layout.size {
            bytes.append(contentsOf: repeatElement(0, count: layout.size - bytes.count))
        }
        for index in 0 ..< layout.size { bytes[index] = 0 }

        var unsupplied: [String] = []

        for member in layout.members {
            // Linear rather than a dictionary: building one would allocate every frame, and a
            // shader's uniform count is small enough that the scan is cheaper anyway.
            let declaration = declarations.first { $0.name == member.name }

            if let values = engine.value(for: member.name) {
                write(values, into: &bytes, member: member)
                continue
            }

            // A reserved name the engine does not know is a real gap: the shader will read
            // zeros and render something that looks broken rather than unsupported.
            if member.name.hasPrefix("g_"), declaration?.isUnannotated == true {
                unsupplied.append(member.name)
            }

            // The property key first: that is what `project.json` names and what the settings
            // UI edits. The uniform's own name is accepted too, since a wallpaper with no
            // annotation on the uniform has no property key to match on.
            if let override = declaration?.material.flatMap({ overrides[$0] })
                ?? overrides[member.name] {
                write(padded(floats(of: override), for: declaration, member: member),
                      into: &bytes, member: member)
                continue
            }

            if let constant = constants[member.name]
                ?? declaration?.material.flatMap({ constants[$0] }) {
                write(padded(floats(of: constant), for: declaration, member: member),
                      into: &bytes, member: member)
                continue
            }

            if let fallback = declaration?.defaultValue {
                write(fallback.floatComponents, into: &bytes, member: member)
            }
        }

        return unsupplied
    }

    /// Completes a short value for the member it is going into.
    ///
    /// Wallpaper Engine writes colours as three components — that is what a `color` property in
    /// `project.json` holds and what the colour picker produces — so a `vec4` tint would be
    /// written with alpha 0 and multiply the layer away entirely. An invisible layer reads as a
    /// broken renderer rather than as a colour with no alpha. Everything else is left short and
    /// the remainder stays zeroed, which is what an unset component should be.
    static func padded(
        _ values: [Float],
        for declaration: ShaderUniformDeclaration?,
        member: UniformBlockMember
    ) -> [Float] {
        guard declaration?.editor == .color,
              member.type == .vec4,
              member.arrayLength == nil,
              values.count == 3
        else { return values }
        return values + [1]
    }

    /// Writes `values` at a member's offset, respecting std140's internal padding.
    ///
    /// Matrices and arrays are not contiguous: a `mat3`'s columns are padded to 16 bytes each,
    /// and an array's elements are spaced by its stride. Writing them as a flat run would
    /// corrupt every column or element after the first.
    static func write(_ values: [Float], into bytes: inout [UInt8], member: UniformBlockMember) {
        guard !values.isEmpty else { return }

        let componentsPerElement: Int
        let elementCount: Int
        switch member.type {
        case .mat3:
            componentsPerElement = 3
            elementCount = 3 * (member.arrayLength ?? 1)
        case .mat4:
            componentsPerElement = 4
            elementCount = 4 * (member.arrayLength ?? 1)
        default:
            componentsPerElement = member.type.componentCount
            elementCount = member.arrayLength ?? 1
        }

        // A matrix's columns are 16 bytes apart whether or not it is in an array; other types
        // use the member's own stride, which is the type's size when it is not an array.
        let elementStride: Int
        switch member.type {
        case .mat3, .mat4: elementStride = 16
        default: elementStride = member.arrayLength == nil ? member.size : member.stride
        }

        var source = values.makeIterator()
        for element in 0 ..< elementCount {
            let base = member.offset + element * elementStride
            for component in 0 ..< componentsPerElement {
                guard let value = source.next() else { return }
                let at = base + component * 4
                guard at + 4 <= bytes.count, at + 4 <= member.offset + member.size else { return }
                withUnsafeBytes(of: value.bitPattern.littleEndian) { raw in
                    for (index, byte) in raw.enumerated() { bytes[at + index] = byte }
                }
            }
        }
    }

    /// Reads a material constant into float components.
    ///
    /// Wallpaper Engine writes vectors as space-separated strings here too, the same as in
    /// shader annotations.
    static func floats(of value: DynamicValue) -> [Float] {
        // Matched on the case rather than through the coercing accessors: `stringValue`
        // promotes a number to its text, which would then be re-parsed through the vector
        // path and pick up a different rounding.
        switch value {
        case .number(let number): [Float(number)]
        case .bool(let flag): [flag ? 1 : 0]
        case .vector3(let vector): [Float(vector.x), Float(vector.y), Float(vector.z)]
        case .string(let text):
            text.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Float($0) }
        case .null: []
        }
    }
}
