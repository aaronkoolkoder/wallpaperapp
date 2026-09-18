import Foundation

// MARK: - Types

/// The GLSL types a Wallpaper Engine uniform can have.
///
/// Deliberately a closed set. An unrecognized type is reported rather than guessed at,
/// because the std140 offsets of everything *after* an unknown member would be wrong —
/// a silent whole-shader corruption rather than one missing property.
public enum ShaderUniformType: String, Sendable, Hashable, Codable, CaseIterable {
    case bool, int, uint, float
    case vec2, vec3, vec4
    case ivec2, ivec3, ivec4
    case bvec2, bvec3, bvec4
    case mat3, mat4
    case sampler2D, sampler3D, samplerCube

    /// True for types that live in a descriptor rather than a constant buffer, and so stay
    /// outside the gathered uniform block.
    public var isOpaque: Bool {
        switch self {
        case .sampler2D, .sampler3D, .samplerCube: true
        default: false
        }
    }

    /// Number of scalar components, for reading and writing default values.
    public var componentCount: Int {
        switch self {
        case .bool, .int, .uint, .float: 1
        case .vec2, .ivec2, .bvec2: 2
        case .vec3, .ivec3, .bvec3: 3
        case .vec4, .ivec4, .bvec4: 4
        case .mat3: 9
        case .mat4: 16
        case .sampler2D, .sampler3D, .samplerCube: 0
        }
    }

    /// std140 base alignment in bytes.
    ///
    /// From the OpenGL spec's std140 rules: scalars align to 4, two-component vectors to 8,
    /// three- and four-component vectors to 16, and matrices align as an array of column
    /// vectors. These are what make the Swift-side buffer writer agree with the offsets
    /// SPIRV-Cross bakes into the generated MSL struct.
    public var std140Alignment: Int {
        switch self {
        case .bool, .int, .uint, .float: 4
        case .vec2, .ivec2, .bvec2: 8
        case .vec3, .vec4, .ivec3, .ivec4, .bvec3, .bvec4: 16
        case .mat3, .mat4: 16
        case .sampler2D, .sampler3D, .samplerCube: 0
        }
    }

    /// std140 size in bytes for a single (non-array) value.
    ///
    /// Note `vec3` is 12, not 16: it *aligns* to 16 but only occupies 12, so a `float`
    /// following one packs into the gap. Rounding it up to 16 here would shift every
    /// subsequent member.
    public var std140Size: Int {
        switch self {
        case .bool, .int, .uint, .float: 4
        case .vec2, .ivec2, .bvec2: 8
        case .vec3, .ivec3, .bvec3: 12
        case .vec4, .ivec4, .bvec4: 16
        // Column-major, each column padded to a vec4.
        case .mat3: 48
        case .mat4: 64
        case .sampler2D, .sampler3D, .samplerCube: 0
        }
    }

    /// True when the components are floating point rather than integer or boolean.
    public var isFloatingPoint: Bool {
        switch self {
        case .float, .vec2, .vec3, .vec4, .mat3, .mat4: true
        default: false
        }
    }
}

/// A uniform's value, in the shape its GLSL type expects.
public enum ShaderUniformValue: Sendable, Hashable, Codable {
    case boolean(Bool)
    case integer(Int)
    case scalar(Double)
    /// Two to sixteen components, in declaration order. Matrices are column-major.
    case vector([Double])
    /// A texture path for sampler uniforms, as written in the annotation.
    case texture(String)

    /// The value as float components, for writing into a constant buffer.
    public var floatComponents: [Float] {
        switch self {
        case .boolean(let flag): [flag ? 1 : 0]
        case .integer(let value): [Float(value)]
        case .scalar(let value): [Float(value)]
        case .vector(let values): values.map(Float.init)
        case .texture: []
        }
    }
}

/// How the property editor presents a uniform. Passed through rather than interpreted.
public enum ShaderUniformEditor: String, Sendable, Hashable, Codable {
    case color
    case slider
    case checkbox
    case int
    case text
    case texture
    case other
}

/// One `uniform` declaration, with whatever the trailing annotation said about it.
public struct ShaderUniformDeclaration: Sendable, Hashable, Codable {
    /// The GLSL identifier, e.g. `g_Color`. Conventionally `g_`-prefixed.
    public var name: String
    public var type: ShaderUniformType

    /// Element count for array declarations, `nil` for scalars.
    public var arrayLength: Int?

    /// The `material` key. This is what a wallpaper's `project.json` sets to override the
    /// default, so a uniform without one is not user-editable.
    public var material: String?

    /// The UI string, usually a `ui_editor_properties_*` localization key.
    public var label: String?

    /// The annotation's `default`, parsed against `type`.
    public var defaultValue: ShaderUniformValue?

    /// Inclusive `[min, max]` from the annotation's `range`, when present.
    public var range: ClosedRange<Double>?

    public var editor: ShaderUniformEditor?

    /// True when the declaration carried no annotation comment at all.
    ///
    /// Engine-supplied uniforms (`g_ModelViewProjection`, `g_Time`) are declared bare; only
    /// user-facing properties are annotated. So this doubles as "the host must supply it".
    public var isUnannotated: Bool

    /// 1-based line in the include-expanded source.
    public var sourceLine: Int?

    public init(
        name: String,
        type: ShaderUniformType,
        arrayLength: Int? = nil,
        material: String? = nil,
        label: String? = nil,
        defaultValue: ShaderUniformValue? = nil,
        range: ClosedRange<Double>? = nil,
        editor: ShaderUniformEditor? = nil,
        isUnannotated: Bool = false,
        sourceLine: Int? = nil
    ) {
        self.name = name
        self.type = type
        self.arrayLength = arrayLength
        self.material = material
        self.label = label
        self.defaultValue = defaultValue
        self.range = range
        self.editor = editor
        self.isUnannotated = isUnannotated
        self.sourceLine = sourceLine
    }
}

public struct UniformParseResult: Sendable, Hashable {
    public var uniforms: [ShaderUniformDeclaration]
    public var diagnostics: [ShaderDiagnostic]

    public init(uniforms: [ShaderUniformDeclaration], diagnostics: [ShaderDiagnostic]) {
        self.uniforms = uniforms
        self.diagnostics = diagnostics
    }

    /// Declarations that belong in the gathered constant buffer, in declaration order.
    public var blockMembers: [ShaderUniformDeclaration] { uniforms.filter { !$0.type.isOpaque } }

    /// Sampler declarations, in declaration order. Their index here is the binding slot
    /// glslang assigns, because it assigns them in declaration order.
    public var samplers: [ShaderUniformDeclaration] { uniforms.filter { $0.type.isOpaque } }
}

// MARK: - Parser

/// Reads `uniform` declarations and their trailing JSON annotations.
///
/// Same posture as `ComboParser`: a declaration whose *annotation* is unreadable still
/// yields a usable uniform (it just isn't user-editable), because dropping it would shift
/// every std140 offset after it. Only a declaration whose *type* is unrecognized is
/// skipped, and that is reported as unsupported rather than degraded — see
/// `ShaderUniformType`.
public enum UniformAnnotationParser {
    public static func parse(_ text: String, shaderName: String) -> UniformParseResult {
        var uniforms: [ShaderUniformDeclaration] = []
        var diagnostics: [ShaderDiagnostic] = []
        var seen: Set<String> = []
        var splitter = CommentSplitter()
        var blockDepth = 0

        for (offset, rawLine) in SourceText.lines(of: text).enumerated() {
            let line = offset + 1
            let scan = splitter.scan(rawLine)
            let code = scan.code

            // Uniforms declared inside a block or a function body are not the default-block
            // uniforms we gather, and `uniform` cannot appear in a function anyway. Tracking
            // brace depth keeps a `uniform` inside an existing uniform block from being
            // hoisted out of it.
            defer { blockDepth += braceDelta(in: code) }
            guard blockDepth == 0 else { continue }

            let (_, trimmed) = SourceText.splitLeadingLayout(
                code.trimmingCharacters(in: .whitespaces)
            )
            guard SourceText.startsWithKeyword(trimmed, "uniform") else { continue }

            // A block declaration (`uniform Foo { ... }`) is already in the shape Vulkan
            // wants and is left alone.
            if trimmed.contains("{") { continue }

            guard let declarator = declarator(inCode: trimmed) else {
                diagnostics.append(ShaderDiagnostic(
                    severity: .degraded,
                    kind: .unrecognizedConstruct,
                    message: "Could not read this uniform declaration; any property bound to it will be missing.",
                    shaderName: shaderName,
                    line: line
                ))
                continue
            }

            guard let type = ShaderUniformType(rawValue: declarator.typeName) else {
                diagnostics.append(ShaderDiagnostic(
                    severity: .unsupported,
                    kind: .unrecognizedConstruct,
                    message: "Uniform \"\(declarator.name)\" has unsupported type \"\(declarator.typeName)\".",
                    shaderName: shaderName,
                    line: line
                ))
                continue
            }

            if seen.contains(declarator.name) {
                // Duplicated by an include expanded twice. Keeping both would declare the
                // same member twice in the gathered block, which does not compile.
                diagnostics.append(ShaderDiagnostic(
                    severity: .info,
                    kind: .unrecognizedConstruct,
                    message: "Uniform \"\(declarator.name)\" is declared more than once; the first declaration wins.",
                    shaderName: shaderName,
                    line: line
                ))
                continue
            }
            seen.insert(declarator.name)

            let annotation = annotationObject(
                inComment: scan.comment,
                shaderName: shaderName,
                line: line,
                uniformName: declarator.name,
                diagnostics: &diagnostics
            )

            uniforms.append(ShaderUniformDeclaration(
                name: declarator.name,
                type: type,
                arrayLength: declarator.arrayLength,
                material: annotation?.value(for: "material")?.stringValue,
                label: annotation?.value(for: "label")?.stringValue,
                defaultValue: annotation.flatMap {
                    defaultValue(
                        $0.value(for: "default"), type: type,
                        isColor: editor($0.value(forAnyOf: ["type", "editor"])) == .color
                    )
                },
                range: annotation.flatMap { range($0.value(for: "range")) },
                editor: annotation.flatMap { editor($0.value(forAnyOf: ["type", "editor"])) },
                isUnannotated: annotation == nil,
                sourceLine: line
            ))
        }

        return UniformParseResult(uniforms: uniforms, diagnostics: diagnostics)
    }

    // MARK: Declaration

    struct Declarator: Sendable, Hashable {
        var typeName: String
        var name: String
        var arrayLength: Int?
    }

    /// Reads `uniform [layout(...)] [precision] <type> <name>[[N]] ;` from a code line.
    ///
    /// Returns `nil` for anything it cannot read confidently, including multi-declarator
    /// lines (`uniform float a, b;`), which the caller reports rather than half-handling.
    static func declarator(inCode code: String) -> Declarator? {
        declarator(inCode: code, keyword: "uniform")
    }

    static func declarator(inCode code: String, keyword: String) -> Declarator? {
        var rest = Substring(code).dropFirst(keyword.count)

        // A declaration spanning lines is not something shipped content does, and accepting
        // a half-read one would be worse than declining it.
        guard let semicolon = rest.firstIndex(of: ";") else { return nil }
        rest = rest[rest.startIndex..<semicolon]

        // Anything after the terminator is a second declaration we are not reading.
        if code[code.index(after: semicolon)...].contains(where: { !$0.isWhitespace }) {
            return nil
        }
        if rest.contains(",") { return nil }

        var tokens = rest
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        // `layout(...)` may be split across tokens; drop everything up to its closing paren.
        while let first = tokens.first, first.hasPrefix("layout") {
            var depth = 0
            var consumed = 0
            for token in tokens {
                consumed += 1
                depth += token.filter { $0 == "(" }.count
                depth -= token.filter { $0 == ")" }.count
                if depth <= 0 { break }
            }
            guard depth <= 0, consumed < tokens.count else { return nil }
            tokens.removeFirst(consumed)
        }

        // Precision and storage qualifiers carry no meaning for us.
        let ignorable: Set<String> = ["lowp", "mediump", "highp", "const", "flat", "smooth", "noperspective"]
        while let first = tokens.first, ignorable.contains(first) { tokens.removeFirst() }

        guard tokens.count == 2 else { return nil }
        let typeName = tokens[0]
        var nameToken = tokens[1]

        var arrayLength: Int?
        if let open = nameToken.firstIndex(of: "[") {
            guard let close = nameToken.firstIndex(of: "]"), close > open else { return nil }
            let inside = nameToken[nameToken.index(after: open)..<close]
                .trimmingCharacters(in: .whitespaces)
            // A size given as a macro or a constant expression is not something we can
            // resolve before the preprocessor runs; declining is safer than assuming one.
            guard let count = Int(inside), count > 0 else { return nil }
            arrayLength = count
            nameToken = String(nameToken[nameToken.startIndex..<open])
        }

        guard SourceText.isIdentifier(typeName), SourceText.isIdentifier(nameToken) else { return nil }
        return Declarator(typeName: typeName, name: nameToken, arrayLength: arrayLength)
    }

    /// Net change in brace depth contributed by a line of code.
    static func braceDelta(in code: String) -> Int {
        code.reduce(into: 0) { total, character in
            if character == "{" { total += 1 }
            if character == "}" { total -= 1 }
        }
    }

    // MARK: Annotation

    static func annotationObject(
        inComment comment: String?,
        shaderName: String,
        line: Int,
        uniformName: String,
        diagnostics: inout [ShaderDiagnostic]
    ) -> JSONishObject? {
        guard let comment, let literal = JSONishExtractor.firstObjectLiteral(in: comment) else {
            return nil
        }
        guard let outcome = JSONishReader.parse(literal),
              let object = outcome.value.objectValue,
              !object.isEmpty
        else {
            diagnostics.append(ShaderDiagnostic(
                severity: .degraded,
                kind: .malformedUniformMetadata,
                message: "The annotation on uniform \"\(uniformName)\" could not be parsed; it will not be editable.",
                shaderName: shaderName,
                line: line
            ))
            return nil
        }
        if outcome.mode == .lenient {
            diagnostics.append(ShaderDiagnostic(
                severity: .info,
                kind: .malformedUniformMetadata,
                message: "The annotation on uniform \"\(uniformName)\" is not strictly valid JSON; recovered with the lenient reader.",
                shaderName: shaderName,
                line: line
            ))
        }
        return object
    }

    /// Parses a `default` against the uniform's declared type.
    ///
    /// Wallpaper Engine writes vectors as space-separated strings (`"1 0.5 0"`) and scalars
    /// as either numbers or numeric strings, so the type drives the reading rather than the
    /// JSON shape.
    static func defaultValue(
        _ value: JSONish?, type: ShaderUniformType, isColor: Bool = false
    ) -> ShaderUniformValue? {
        guard let value else { return nil }

        if type.isOpaque {
            return value.stringValue.map(ShaderUniformValue.texture)
        }

        let components = numericComponents(value)
        guard !components.isEmpty else { return nil }

        switch type {
        case .bool, .bvec2, .bvec3, .bvec4:
            if type.componentCount == 1 {
                return .boolean(components[0] != 0)
            }
        case .int, .uint:
            return .integer(Int(components[0].rounded()))
        case .float:
            return .scalar(components[0])
        default:
            break
        }

        let expected = type.componentCount
        guard expected > 1 else { return .scalar(components[0]) }

        // A default with the wrong component count is repaired by padding rather than
        // dropped: a partially-correct colour is closer to the author's intent than black.
        var padded = Array(components.prefix(expected))
        while padded.count < expected { padded.append(padding(for: type, at: padded.count, isColor: isColor)) }
        return .vector(padded)
    }

    /// What a missing component should be.
    ///
    /// Zero for almost everything, but a colour is the exception and an important one: Wallpaper
    /// Engine writes colours as three components, and a `vec4` tint padded with alpha 0
    /// multiplies the layer away entirely. An invisible layer reads as a broken renderer rather
    /// than as a colour with no alpha.
    static func padding(for type: ShaderUniformType, at index: Int, isColor: Bool) -> Double {
        isColor && type == .vec4 && index == 3 ? 1 : 0
    }

    /// Flattens a JSON value into numbers, accepting `"1 0.5 0"`, `[1, 0.5, 0]` and `1`.
    static func numericComponents(_ value: JSONish) -> [Double] {
        switch value {
        case .string(let text):
            return text
                .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
                .compactMap { Double($0) }
        case .array(let elements):
            return elements.compactMap(\.doubleValue)
        default:
            return value.doubleValue.map { [$0] } ?? []
        }
    }

    static func range(_ value: JSONish?) -> ClosedRange<Double>? {
        guard let value else { return nil }
        let bounds = numericComponents(value)
        guard bounds.count >= 2, bounds[0].isFinite, bounds[1].isFinite else { return nil }
        // Reversed bounds appear in shipped content; ordering them is what the editor does.
        return min(bounds[0], bounds[1])...max(bounds[0], bounds[1])
    }

    static func editor(_ value: JSONish?) -> ShaderUniformEditor? {
        guard let name = value?.stringValue?.lowercased() else { return nil }
        return ShaderUniformEditor(rawValue: name) ?? .other
    }
}
