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

    /// Which engine value a reserved name means, worked out once rather than matched per draw.
    ///
    /// The names are fixed at compile time and the values change every frame, so matching them
    /// belongs with the compile. A profile of the heaviest effect scene in the test library
    /// spent more of its frame in `String.hash` and string comparison — inside this lookup and
    /// the dictionaries beside it — than in anything to do with drawing.
    public enum Slot: Sendable, Hashable {
        case modelViewProjection
        case time
        case dayTime
        case pointerPosition
        case screen
        case texelSize
        case texelSizeHalf
        case audioSpectrumLeft
        case audioSpectrumRight
        /// `g_Texture0Resolution` through `g_Texture7Resolution`.
        case textureResolution(Int)

        /// The slot a reserved name means, or nil when this app supplies no such value.
        ///
        /// Several spellings of the matrix are in use across shipped content, so all of the
        /// ones observed map to the same value rather than only the one this app prefers.
        public static func named(_ name: String) -> Slot? {
            switch name {
            case "g_ModelViewProjection", "g_ModelViewProjectionMatrix",
                 "g_ModelViewProjectionMatrixInverse", "g_ViewProjectionMatrix":
                .modelViewProjection
            case "g_Time", "g_AnimationTime", "g_GlobalTime": .time
            case "g_DayTime": .dayTime
            case "g_PointerPosition": .pointerPosition
            case "g_Screen": .screen
            case "g_TexelSize": .texelSize
            case "g_TexelSizeHalf": .texelSizeHalf
            case "g_AudioSpectrum16Left": .audioSpectrumLeft
            case "g_AudioSpectrum16Right": .audioSpectrumRight
            default: EngineUniforms.textureResolutionSlot(in: name).map { .textureResolution($0) }
            }
        }
    }

    /// Writes a slot's value into `scratch` and answers how many floats it wrote, or nil when
    /// this frame has nothing for it.
    ///
    /// Fills caller-owned storage rather than returning an array: this runs for every uniform
    /// of every draw of every frame, and an array per call is an allocation per call.
    public func read(_ slot: Slot, into scratch: inout [Float]) -> Int? {
        if scratch.count < 16 { scratch.append(contentsOf: repeatElement(0, count: 16 - scratch.count)) }
        switch slot {
        case .modelViewProjection:
            var index = 0
            for column in [
                modelViewProjection.columns.0, modelViewProjection.columns.1,
                modelViewProjection.columns.2, modelViewProjection.columns.3,
            ] {
                scratch[index] = column.x
                scratch[index + 1] = column.y
                scratch[index + 2] = column.z
                scratch[index + 3] = column.w
                index += 4
            }
            return 16
        case .time:
            scratch[0] = time
            return 1
        case .dayTime:
            scratch[0] = dayTime
            return 1
        case .pointerPosition:
            scratch[0] = pointerPosition.x
            scratch[1] = pointerPosition.y
            return 2
        case .screen:
            scratch[0] = screenSize.x
            scratch[1] = screenSize.y
            return 2
        case .texelSize:
            scratch[0] = 1 / max(screenSize.x, 1)
            scratch[1] = 1 / max(screenSize.y, 1)
            return 2
        case .texelSizeHalf:
            scratch[0] = 0.5 / max(screenSize.x, 1)
            scratch[1] = 0.5 / max(screenSize.y, 1)
            return 2
        case .audioSpectrumLeft:
            guard !audioSpectrumLeft.isEmpty else { return nil }
            for (index, value) in audioSpectrumLeft.prefix(16).enumerated() { scratch[index] = value }
            return min(16, audioSpectrumLeft.count)
        case .audioSpectrumRight:
            guard !audioSpectrumRight.isEmpty else { return nil }
            for (index, value) in audioSpectrumRight.prefix(16).enumerated() { scratch[index] = value }
            return min(16, audioSpectrumRight.count)
        case .textureResolution(let index):
            guard index < textureResolutions.count else { return nil }
            let resolution = textureResolutions[index]
            scratch[0] = resolution.x
            scratch[1] = resolution.y
            scratch[2] = resolution.z
            scratch[3] = resolution.w
            return 4
        }
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

/// How every uniform in one constant buffer is filled, worked out once per shader.
///
/// The work this removes is the work of deciding: which of the four sources a uniform comes
/// from, and under which key. None of that changes between frames — the names are fixed when
/// the shader compiles — but it was redone for every uniform of every draw, as a string switch
/// and a pair of dictionary lookups. On the heaviest effect scene in the test library that was
/// the single largest thing in the frame.
public struct UniformPlan: Sendable {
    /// One uniform, with everything about it that can be settled in advance.
    public struct Step: Sendable {
        public var member: UniformBlockMember
        /// The engine value this takes, when it is one the app supplies.
        public var engine: EngineUniforms.Slot?
        /// The property key the user's setting is under, then the uniform's own name.
        public var overrideKeys: [String]
        public var constantKeys: [String]
        /// The annotation's default, already in float components.
        public var fallback: [Float]?
        /// A reserved name the engine does not know, which the report should mention.
        public var isUnsupplied: Bool
        /// A three-component colour going into a `vec4` needs its alpha completing.
        public var padsColourAlpha: Bool
    }

    public var steps: [Step]
    public var size: Int

    public init() {
        steps = []
        size = 0
    }

    public init(layout: UniformBlockLayout, declarations: [ShaderUniformDeclaration]) {
        size = layout.size
        steps = layout.members.map { member in
            // Linear, but once per shader rather than once per draw: a shader's uniform count
            // is small and building a dictionary here would cost more than it saves.
            let declaration = declarations.first { $0.name == member.name }
            let engine = EngineUniforms.Slot.named(member.name)

            var overrideKeys: [String] = []
            var constantKeys: [String] = []
            if engine == nil {
                // The property key first: that is what `project.json` names and what the
                // settings UI edits. The uniform's own name is accepted too, since a wallpaper
                // with no annotation on the uniform has no property key to match on.
                if let material = declaration?.material {
                    overrideKeys.append(material)
                    constantKeys.append(material)
                }
                overrideKeys.append(member.name)
                constantKeys.insert(member.name, at: 0)
            }

            return Step(
                member: member,
                engine: engine,
                overrideKeys: overrideKeys,
                constantKeys: constantKeys,
                fallback: engine == nil ? declaration?.defaultValue?.floatComponents : nil,
                isUnsupplied: engine == nil && member.name.hasPrefix("g_")
                    && declaration?.isUnannotated == true,
                padsColourAlpha: declaration?.editor == .color
                    && member.type == .vec4 && member.arrayLength == nil
            )
        }
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

    /// Fills a buffer from a plan, which is the form the render path uses.
    ///
    /// `scratch` and `values` are caller-owned so that a frame allocates nothing here: both
    /// grow once to the largest uniform a shader has and are reused for every draw after.
    @discardableResult
    public static func fill(
        into bytes: inout [UInt8],
        plan: UniformPlan,
        constants: [String: DynamicValue] = [:],
        overrides: [String: DynamicValue] = [:],
        engine: EngineUniforms,
        scratch: inout [Float],
        unsupplied: inout [String]
    ) -> Int {
        if bytes.count < plan.size {
            bytes.append(contentsOf: repeatElement(0, count: plan.size - bytes.count))
        }
        for index in 0 ..< plan.size { bytes[index] = 0 }

        for step in plan.steps {
            if let slot = step.engine {
                if let count = engine.read(slot, into: &scratch) {
                    scratch.withUnsafeBufferPointer { values in
                        write(UnsafeBufferPointer(rebasing: values[0 ..< count]),
                              into: &bytes, member: step.member)
                    }
                }
                continue
            }

            if step.isUnsupplied { unsupplied.append(step.member.name) }

            if let value = step.overrideKeys.lazy.compactMap({ overrides[$0] }).first
                ?? step.constantKeys.lazy.compactMap({ constants[$0] }).first {
                var components = floats(of: value)
                if step.padsColourAlpha, components.count == 3 { components.append(1) }
                components.withUnsafeBufferPointer { write($0, into: &bytes, member: step.member) }
                continue
            }

            if let fallback = step.fallback {
                fallback.withUnsafeBufferPointer { write($0, into: &bytes, member: step.member) }
            }
        }

        return plan.size
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
        values.withUnsafeBufferPointer { write($0, into: &bytes, member: member) }
    }

    static func write(
        _ values: UnsafeBufferPointer<Float>, into bytes: inout [UInt8], member: UniformBlockMember
    ) {
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
