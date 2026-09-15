import Foundation

/// One selectable value of a combo, as shown in Wallpaper Engine's property editor.
public struct ComboOption: Sendable, Hashable, Codable {
    /// The raw label from the metadata. Usually a `ui_editor_properties_*` localization
    /// key rather than display text.
    public var label: String
    /// The integer the combo macro takes when this option is chosen.
    public var value: Int

    public init(label: String, value: Int) {
        self.label = label
        self.value = value
    }
}

/// A `COMBO` variant declaration parsed out of a Wallpaper Engine shader.
///
/// Combos are Wallpaper Engine's shader variant system: each one becomes a preprocessor
/// macro whose integer value the shader branches on with `#if BLOOM`. A shader with N
/// combos describes a variant space, and each point in that space is a separate compiled
/// program — which is exactly why PLAN.md §5.4 pays for compilation once at import.
public struct ComboDeclaration: Sendable, Hashable, Codable {
    /// The macro name, e.g. `BLOOM`. Always a valid GLSL identifier; declarations whose
    /// name is not are rejected during parsing so nothing unvetted reaches a `#define`.
    public var name: String

    /// The value used when the wallpaper's material does not override the combo.
    public var defaultValue: Int

    /// The editor widget type, e.g. `"options"`. Passed through verbatim.
    public var type: String?

    /// Selectable values, in declaration order. Empty when the metadata declares none.
    public var options: [ComboOption]

    /// The `material` field verbatim.
    ///
    /// `TODO(verify):` in uniform annotations `material` is the property key in
    /// `project.json` and `label` is the UI string, but the combo example in the spec
    /// puts a `ui_editor_properties_*` value in `material` with no `label` at all. Both
    /// fields are stored raw rather than reinterpreted, because guessing which one binds
    /// to `general.properties` would silently mis-wire the settings UI.
    public var material: String?

    /// The `label` field verbatim. See the note on `material`.
    public var label: String?

    /// 1-based line in the emitted GLSL (see `PreprocessedShader.lineMap`) when the
    /// declaration came through `ShaderPreprocessor`; otherwise a line in the text that
    /// was parsed.
    public var sourceLine: Int?

    public init(
        name: String,
        defaultValue: Int = 0,
        type: String? = nil,
        options: [ComboOption] = [],
        material: String? = nil,
        label: String? = nil,
        sourceLine: Int? = nil
    ) {
        self.name = name
        self.defaultValue = defaultValue
        self.type = type
        self.options = options
        self.material = material
        self.label = label
        self.sourceLine = sourceLine
    }
}

public struct ComboParseResult: Sendable, Hashable {
    public var combos: [ComboDeclaration]
    public var diagnostics: [ShaderDiagnostic]

    public init(combos: [ComboDeclaration], diagnostics: [ShaderDiagnostic]) {
        self.combos = combos
        self.diagnostics = diagnostics
    }
}

/// Parses Wallpaper Engine's `// [COMBO] { ... }` structured comments.
///
/// Posture: a malformed combo annotation costs one variant switch, while failing the
/// whole shader costs the wallpaper. So a payload that neither the strict nor the
/// lenient reader can turn into a usable declaration produces a diagnostic and is
/// skipped — never a thrown error.
public enum ComboParser {
    /// The comment tag that introduces a combo declaration.
    public static let tag = "[COMBO]"

    public static func parse(_ text: String, shaderName: String) -> ComboParseResult {
        var combos: [ComboDeclaration] = []
        var diagnostics: [ShaderDiagnostic] = []
        var seen: Set<String> = []
        var splitter = CommentSplitter()

        for (offset, rawLine) in SourceText.lines(of: text).enumerated() {
            let line = offset + 1
            let scan = splitter.scan(rawLine)
            guard let payload = comboPayload(inComment: scan.comment) else { continue }

            guard let literal = JSONishExtractor.firstObjectLiteral(in: payload) else {
                diagnostics.append(ShaderDiagnostic(
                    severity: .degraded,
                    kind: .malformedComboMetadata,
                    message: "[COMBO] comment carries no JSON object; the variant it declares will not be exposed.",
                    shaderName: shaderName,
                    line: line
                ))
                continue
            }

            guard let outcome = JSONishReader.parse(literal),
                  let object = outcome.value.objectValue,
                  !object.isEmpty
            else {
                diagnostics.append(ShaderDiagnostic(
                    severity: .degraded,
                    kind: .malformedComboMetadata,
                    message: "[COMBO] metadata could not be parsed as an object; the variant it declares will not be exposed.",
                    shaderName: shaderName,
                    line: line
                ))
                continue
            }

            if outcome.mode == .lenient {
                diagnostics.append(ShaderDiagnostic(
                    severity: .info,
                    kind: .malformedComboMetadata,
                    message: "[COMBO] metadata is not strictly valid JSON; recovered with the lenient reader.",
                    shaderName: shaderName,
                    line: line
                ))
            }

            // TODO(verify): `combo` is the key named in the spec. `name` is accepted as a
            // fallback only because it is the obvious alternative spelling; it has not
            // been observed in real content.
            guard let name = object.value(forAnyOf: ["combo", "name"])?.stringValue,
                  SourceText.isIdentifier(name)
            else {
                diagnostics.append(ShaderDiagnostic(
                    severity: .degraded,
                    kind: .malformedComboMetadata,
                    message: "[COMBO] metadata has no usable \"combo\" macro name; the variant it declares will not be exposed.",
                    shaderName: shaderName,
                    line: line
                ))
                continue
            }

            if seen.contains(name) {
                diagnostics.append(ShaderDiagnostic(
                    severity: .info,
                    kind: .duplicateCombo,
                    message: "Combo \"\(name)\" is declared more than once; the first declaration wins.",
                    shaderName: shaderName,
                    line: line
                ))
                continue
            }
            seen.insert(name)

            combos.append(ComboDeclaration(
                name: name,
                defaultValue: object.value(for: "default")?.intValue ?? 0,
                type: object.value(for: "type")?.stringValue,
                options: parseOptions(object.value(for: "options")),
                material: object.value(for: "material")?.stringValue,
                label: object.value(for: "label")?.stringValue,
                sourceLine: line
            ))
        }

        return ComboParseResult(combos: combos, diagnostics: diagnostics)
    }

    /// Returns the text following `[COMBO]` when `comment` is a combo annotation.
    ///
    /// Tolerates `//[COMBO]{...}` with no spacing, and matches the tag
    /// case-insensitively. `TODO(verify):` only the uppercase spelling has been described.
    static func comboPayload(inComment comment: String?) -> String? {
        guard let comment else { return nil }
        let trimmed = comment.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= tag.count else { return nil }
        guard trimmed.prefix(tag.count).uppercased() == tag else { return nil }
        return String(trimmed.dropFirst(tag.count))
    }

    /// Reads a combo's option list.
    ///
    /// `TODO(verify):` three shapes are accepted because the spec does not pin one down —
    /// an object mapping label to value, an array of `{label, value}` objects, and a bare
    /// array where the index is the value. Only the object form is implied by the
    /// example in PLAN.md.
    static func parseOptions(_ value: JSONish?) -> [ComboOption] {
        guard let value else { return [] }
        switch value {
        case .object(let object):
            return object.pairs.enumerated().map { index, pair in
                ComboOption(label: pair.key, value: pair.value.intValue ?? index)
            }
        case .array(let elements):
            return elements.enumerated().compactMap { index, element in
                switch element {
                case .string(let label):
                    return ComboOption(label: label, value: index)
                case .number(let number):
                    return ComboOption(label: String(Int(number)), value: Int(number))
                case .object(let object):
                    let label = object.value(forAnyOf: ["label", "text", "name"])?.stringValue
                    let intValue = object.value(forAnyOf: ["value", "combo"])?.intValue
                    guard let label else { return nil }
                    return ComboOption(label: label, value: intValue ?? index)
                default:
                    return nil
                }
            }
        default:
            return []
        }
    }

    /// The combo values a shader uses when nothing overrides them.
    public static func defaultValues(of combos: [ComboDeclaration]) -> [String: Int] {
        var values: [String: Int] = [:]
        for combo in combos { values[combo.name] = combo.defaultValue }
        return values
    }

    /// A stable, order-independent identifier for one point in a shader's variant space.
    ///
    /// Dictionaries have no defined iteration order, so the key is built from sorted
    /// names: the same selection always produces the same string regardless of how the
    /// dictionary was populated. The result is safe to use directly as a filename
    /// component — names are sanitized to `[A-Za-z0-9_]`, and an over-long key collapses
    /// to a deterministic hash so a shader with many combos cannot blow the filename
    /// limit.
    public static func variantKey(for values: [String: Int]) -> String {
        guard !values.isEmpty else { return "base" }
        let joined = values
            .sorted { $0.key < $1.key }
            .map { "\(sanitize($0.key))=\($0.value)" }
            .joined(separator: "+")
        if joined.utf8.count <= 100 { return joined }
        return "h" + String(ShaderHashing.sha256Hex(joined).prefix(32))
    }

    /// Restricts a combo name to characters that are safe in a filename.
    ///
    /// Real combo names are GLSL identifiers and pass through unchanged; this only
    /// matters for values injected from a material's JSON, which is untrusted input.
    static func sanitize(_ name: String) -> String {
        let mapped = name.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_")) ? ch : "_"
        }
        return mapped.isEmpty ? "_" : String(mapped)
    }
}
