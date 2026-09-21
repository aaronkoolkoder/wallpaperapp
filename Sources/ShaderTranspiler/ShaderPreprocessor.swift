import Foundation

// MARK: - Result

/// A shader turned into GLSL the backend will accept, plus everything the renderer needs to
/// bind against it.
public struct PreprocessedShader: Sendable, Hashable {
    public var name: String
    public var stage: ShaderStage

    /// Vulkan-flavoured GLSL 450, ready for `TranspilerBackend`.
    public var glsl: String

    /// Lines the preprocessor added above the body, so a compiler error reported against
    /// `glsl` can be traced back to the file the author wrote.
    public var prologueLineCount: Int

    public var combos: [ComboDeclaration]

    /// The combo values this variant was built with, defaults merged with overrides.
    public var comboValues: [String: Int]

    /// Every uniform found, opaque and not, in declaration order.
    public var uniforms: [ShaderUniformDeclaration]

    /// Byte layout of the gathered constant buffer. Empty when the shader has no non-opaque
    /// uniforms, in which case no block is emitted.
    public var layout: UniformBlockLayout

    /// Sampler declarations. These stay in the body; the slot each one ends up in comes from
    /// the backend's reflection, not from this order.
    public var samplers: [ShaderUniformDeclaration]

    /// Varying names in the order locations were assigned, so the matching stage can agree.
    public var varyings: [String]

    public var includedFiles: [String]
    public var diagnostics: [ShaderDiagnostic]

    /// Origin of each body line, parallel to the include-expanded source.
    public var lineMap: [SourceLocation]

    /// Content hash of the emitted GLSL. This is the cache key, and it covers the combo
    /// defines because they are part of what is hashed.
    public var sourceHash: String

    public init(
        name: String,
        stage: ShaderStage,
        glsl: String,
        prologueLineCount: Int,
        combos: [ComboDeclaration],
        comboValues: [String: Int],
        uniforms: [ShaderUniformDeclaration],
        layout: UniformBlockLayout,
        samplers: [ShaderUniformDeclaration],
        varyings: [String],
        includedFiles: [String],
        diagnostics: [ShaderDiagnostic],
        lineMap: [SourceLocation],
        sourceHash: String
    ) {
        self.name = name
        self.stage = stage
        self.glsl = glsl
        self.prologueLineCount = prologueLineCount
        self.combos = combos
        self.comboValues = comboValues
        self.uniforms = uniforms
        self.layout = layout
        self.samplers = samplers
        self.varyings = varyings
        self.includedFiles = includedFiles
        self.diagnostics = diagnostics
        self.lineMap = lineMap
        self.sourceHash = sourceHash
    }

    /// Where a 1-based line of `glsl` came from, or `nil` for a prologue line.
    ///
    /// Without this a glslang error names a line in a file that does not exist on disk,
    /// because the prologue shifted everything and includes were flattened.
    public func origin(ofEmittedLine line: Int) -> SourceLocation? {
        let bodyLine = line - prologueLineCount
        guard bodyLine >= 1, bodyLine <= lineMap.count else { return nil }
        return lineMap[bodyLine - 1]
    }
}

public enum ShaderPreprocessorError: Error, LocalizedError {
    case includeFailed(IncludeError)

    public var errorDescription: String? {
        switch self {
        case .includeFailed(let error): error.description
        }
    }
}

// MARK: - Preprocessor

/// Turns Wallpaper Engine's GLSL into GLSL that glslang will compile for Vulkan.
///
/// Four things make that more than a pass-through, each confirmed against the vendored
/// toolchain rather than assumed:
///
/// 1. Vulkan forbids non-opaque uniforms outside a block, and every Wallpaper Engine shader
///    declares them at global scope. They are gathered into one std140 block, which also
///    gives the renderer a byte layout to fill.
/// 2. `varying` and `attribute` were removed from core GLSL in 4.20; glslang rejects them
///    outright rather than warning.
/// 3. `texture2D` and friends no longer exist, and `gl_FragColor` was removed with them.
/// 4. The two stages are compiled as separate programs, so glslang cannot match their
///    varyings for them. Locations are assigned here from the union of both stages'
///    varyings, which is what `preprocessPair` is for.
public struct ShaderPreprocessor: Sendable {
    /// Name of the block the gathered uniforms are emitted into.
    public static let uniformBlockName = "DioramaUniforms"

    /// The header prepended to every shader, as Wallpaper Engine's own compiler does.
    public static let implicitHeader = "common.h"

    /// Replacement for the removed `gl_FragColor`.
    public static let fragmentOutputName = "diorama_FragColor"

    /// Legacy builtins and the core functions that replaced them.
    ///
    /// Applied per identifier token rather than by substring, so `texture2DLod` cannot be
    /// half-rewritten into `textureLod` by an earlier `texture2D` rule.
    /// Identifiers that were ordinary names in the GLSL these shaders were written against and
    /// are reserved keywords in the core profile they are compiled as.
    ///
    /// `sample` is the one that actually bites: it became a storage qualifier in GLSL 4.20, and
    /// shipped shaders use it as a plain variable. glslang answers with "syntax error, unexpected
    /// SAMPLE", which points at the line without saying why a perfectly ordinary name is
    /// suddenly illegal.
    static let reservedRenames: [String: String] = [
        "sample": "we_sample",
        "filter": "we_filter",
        "buffer": "we_buffer",
        "shared": "we_shared",
        "active": "we_active",
        "common": "we_common",
        "partition": "we_partition",
        "resource": "we_resource",
    ]

    static let builtinReplacements: [String: String] = [
        "texture2D": "texture",
        "texture2DProj": "textureProj",
        "texture2DLod": "textureLod",
        "texture2DProjLod": "textureProjLod",
        "texture3D": "texture",
        "texture3DProj": "textureProj",
        "texture3DLod": "textureLod",
        "textureCube": "texture",
        "textureCubeLod": "textureLod",
        "shadow2D": "texture",
        "shadow2DProj": "textureProj",
    ]

    /// Builtin renames and reserved-word renames in one table, so a token is looked at once.
    static let allIdentifierRewrites: [String: String] =
        builtinReplacements.merging(reservedRenames) { builtin, _ in builtin }

    public var includeResolver: IncludeResolver

    public init(includeResolver: IncludeResolver = IncludeResolver()) {
        self.includeResolver = includeResolver
    }

    // MARK: Pair

    /// Preprocesses a vertex and fragment shader so their varyings agree.
    ///
    /// Compiling the stages separately means glslang assigns each one's locations in
    /// isolation. When the two stages declare different sets — which happens as soon as a
    /// combo switches one off — the assignments disagree and the fragment shader reads a
    /// different varying than the vertex shader wrote. Assigning from the union here removes
    /// that whole class of bug.
    public func preprocessPair(
        vertex: ShaderSource,
        fragment: ShaderSource,
        provider: ShaderFileProvider,
        comboOverrides: [String: Int] = [:],
        boundTextures: Set<Int> = []
    ) throws -> (vertex: PreprocessedShader, fragment: PreprocessedShader) {
        let vertexScan = try varyingScan(of: vertex, provider: provider)
        let fragmentScan = try varyingScan(of: fragment, provider: provider)

        var union: [String] = vertexScan.unlocated
        for name in fragmentScan.unlocated where !union.contains(name) { union.append(name) }

        let locations = Self.assignLocations(
            to: union, avoiding: vertexScan.reserved.union(fragmentScan.reserved)
        )

        // Decided once for the pair, for the same reason as the varyings. A sampler is usually
        // declared only in the fragment stage while its combo is tested in both — foliage
        // sway's vertex shader computes the mask's UV under `#if MASK == 1` — so letting each
        // stage decide alone would switch the mask on in one and off in the other.
        var samplerCombos: [String: Int] = [:]
        for source in [vertex, fragment] {
            for (name, value) in try samplerComboValues(
                of: source, provider: provider,
                overrides: comboOverrides, boundTextures: boundTextures
            ) {
                samplerCombos[name] = max(samplerCombos[name] ?? 0, value)
            }
        }

        // And the combos a shader declares in `// [COMBO]` comments. Wallpaper Engine sets a
        // pass's combos for both stages, but a pair often declares one in only one of them:
        // godrays' downsample declares NOISE in its fragment shader while its vertex shader
        // writes the noise coordinates under the same `#if`. Resolved one stage at a time, the
        // vertex stage came out without them and the pipeline would not link — "fragment input
        // user(locn1) not written by vertex shader", in five wallpapers of a real library.
        var pairCombos: [ComboDeclaration] = []
        for source in [vertex, fragment] {
            for combo in try comboDeclarations(of: source, provider: provider)
            where !pairCombos.contains(where: { $0.name == combo.name }) {
                pairCombos.append(combo)
            }
        }

        return (
            try preprocess(
                vertex, provider: provider,
                comboOverrides: comboOverrides, varyingLocations: locations,
                samplerCombos: samplerCombos, pairCombos: pairCombos
            ),
            try preprocess(
                fragment, provider: provider,
                comboOverrides: comboOverrides, varyingLocations: locations,
                samplerCombos: samplerCombos, pairCombos: pairCombos
            )
        )
    }

    private func comboDeclarations(
        of source: ShaderSource, provider: ShaderFileProvider
    ) throws -> [ComboDeclaration] {
        let resolved: ResolvedShaderSource
        do {
            resolved = try includeResolver.resolve(
                source, provider: provider, prelude: [Self.implicitHeader]
            )
        } catch let error as IncludeError {
            throw ShaderPreprocessorError.includeFailed(error)
        }
        return ComboParser.parse(resolved.text, shaderName: source.name).combos
    }

    /// The combo each sampler switches on, and its value: 1 when a texture is bound to that
    /// sampler — `boundTextures` holds the N of every bound `g_TextureN` — and 0 otherwise,
    /// unless the material sets it outright.
    static func samplerComboValues(
        in uniforms: UniformParseResult, overrides: [String: Int], boundTextures: Set<Int>
    ) -> [String: Int] {
        var values: [String: Int] = [:]
        for sampler in uniforms.samplers {
            guard let name = sampler.combo else { continue }
            let slot = sampler.name.hasPrefix("g_Texture")
                ? Int(sampler.name.dropFirst("g_Texture".count)) : nil
            let bound = slot.map { boundTextures.contains($0) } ?? false
            values[name] = max(values[name] ?? 0, overrides[name] ?? (bound ? 1 : 0))
        }
        return values
    }

    private func samplerComboValues(
        of source: ShaderSource, provider: ShaderFileProvider,
        overrides: [String: Int], boundTextures: Set<Int>
    ) throws -> [String: Int] {
        let resolved: ResolvedShaderSource
        do {
            resolved = try includeResolver.resolve(
                source, provider: provider, prelude: [Self.implicitHeader]
            )
        } catch let error as IncludeError {
            throw ShaderPreprocessorError.includeFailed(error)
        }
        return Self.samplerComboValues(
            in: UniformAnnotationParser.parse(resolved.text, shaderName: source.name),
            overrides: overrides, boundTextures: boundTextures
        )
    }

    // MARK: Single stage

    public func preprocess(
        _ source: ShaderSource,
        provider: ShaderFileProvider,
        comboOverrides: [String: Int] = [:],
        varyingLocations: [String: Int]? = nil,
        boundTextures: Set<Int> = [],
        samplerCombos: [String: Int]? = nil,
        pairCombos: [ComboDeclaration] = []
    ) throws -> PreprocessedShader {
        // Wallpaper Engine's common header is implicit, not included. Most shipped shaders call
        // `mul`, `frac`, `texSample2D` and `CAST3` without ever naming a header — only 16 of the
        // 56 in a real library `#include "common.h"` while 28 of them call `mul`. Prepending it
        // is what its compiler evidently does; the header's own include guard makes a shader
        // that *does* include it harmless.
        let resolved: ResolvedShaderSource
        do {
            resolved = try includeResolver.resolve(
                source, provider: provider, prelude: [Self.implicitHeader]
            )
        } catch let error as IncludeError {
            throw ShaderPreprocessorError.includeFailed(error)
        }

        var diagnostics: [ShaderDiagnostic] = []

        let comboResult = ComboParser.parse(resolved.text, shaderName: source.name)
        diagnostics.append(contentsOf: comboResult.diagnostics)

        let uniformResult = UniformAnnotationParser.parse(resolved.text, shaderName: source.name)
        diagnostics.append(contentsOf: uniformResult.diagnostics)

        var declaredCombos = comboResult.combos
        for combo in pairCombos where !declaredCombos.contains(where: { $0.name == combo.name }) {
            declaredCombos.append(combo)
        }
        let comboValues = resolveComboValues(
            declared: declaredCombos,
            overrides: comboOverrides,
            shaderName: source.name,
            diagnostics: &diagnostics
        )

        // A shader that defines a combo macro itself would collide with the one we inject, and
        // a redefinition with a different value is a hard error in the preprocessor.
        let selfDefined = selfDefinedMacros(in: resolved.text)
        var injectable: [(name: String, value: Int)] = []
        for combo in declaredCombos {
            guard let value = comboValues[combo.name] else { continue }
            if selfDefined.contains(combo.name) {
                diagnostics.append(ShaderDiagnostic(
                    severity: .degraded,
                    kind: .comboMacroConflict,
                    message: "Combo \"\(combo.name)\" is also defined by the shader itself; the shader's own definition is used and the property will have no effect.",
                    shaderName: source.name,
                    line: combo.sourceLine
                ))
                continue
            }
            injectable.append((combo.name, value))
        }

        // Combos a sampler switches on. Without these the macro was never defined, `#if MASK ==
        // 1` was always false, and a painted mask was compiled out of the very shader it was
        // bound to. A pair passes in what it decided for both stages; a lone stage decides
        // from its own samplers.
        let declared = Set(declaredCombos.map(\.name))
        let samplerValues = samplerCombos ?? Self.samplerComboValues(
            in: uniformResult, overrides: comboOverrides, boundTextures: boundTextures
        )
        for (name, value) in samplerValues.sorted(by: { $0.key < $1.key }) {
            guard !declared.contains(name), !selfDefined.contains(name),
                  !injectable.contains(where: { $0.name == name })
            else { continue }
            injectable.append((name, value))
        }

        // Every line a gathered declaration occupies, not just its first: one written across
        // several lines would otherwise leave its tail behind, which does not compile.
        var uniformLines: Set<Int> = []
        for member in uniformResult.blockMembers {
            guard let start = member.sourceLine else { continue }
            for line in start ..< (start + member.lineCount) { uniformLines.insert(line) }
        }

        // With no table from a paired stage, assign from this stage alone — still avoiding
        // any location the author claimed.
        let scan = Self.varyingScan(inText: resolved.text, stage: source.stage)
        let locations = varyingLocations
            ?? Self.assignLocations(to: scan.unlocated, avoiding: scan.reserved)

        let body = rewriteBody(
            resolved: resolved,
            stage: source.stage,
            shaderName: source.name,
            removingLines: uniformLines,
            varyingLocations: locations,
            diagnostics: &diagnostics
        )

        let layout = UniformBlockLayout.std140(for: uniformResult.blockMembers)

        let prologue = buildPrologue(
            combos: injectable,
            members: uniformResult.blockMembers,
            emitFragmentOutput: source.stage == .fragment && body.usesLegacyFragmentOutput
        )

        let glsl = SourceText.join(prologue + body.lines) + "\n"

        return PreprocessedShader(
            name: source.name,
            stage: source.stage,
            glsl: glsl,
            prologueLineCount: prologue.count,
            combos: comboResult.combos,
            comboValues: comboValues,
            uniforms: uniformResult.uniforms,
            layout: layout,
            samplers: uniformResult.samplers,
            varyings: body.varyings,
            includedFiles: resolved.includedFiles,
            diagnostics: diagnostics,
            lineMap: resolved.lineMap,
            sourceHash: ShaderHashing.sha256Hex(glsl)
        )
    }

    // MARK: Combos

    func resolveComboValues(
        declared: [ComboDeclaration],
        overrides: [String: Int],
        shaderName: String,
        diagnostics: inout [ShaderDiagnostic]
    ) -> [String: Int] {
        var values = ComboParser.defaultValues(of: declared)
        let names = Set(declared.map(\.name))

        for (name, value) in overrides.sorted(by: { $0.key < $1.key }) {
            guard names.contains(name) else {
                // A material can name a combo the shader does not declare, usually because
                // the two came from different versions of a pack. Injecting it anyway would
                // define a macro nothing reads; saying so is more useful than either.
                diagnostics.append(ShaderDiagnostic(
                    severity: .info,
                    kind: .undeclaredCombo,
                    message: "Combo \"\(name)\" was set but this shader does not declare it; the setting is ignored.",
                    shaderName: shaderName
                ))
                continue
            }
            values[name] = value
        }
        return values
    }

    /// Macro names the shader `#define`s or `#undef`s itself.
    static func selfDefinedMacrosImplementation(in text: String) -> Set<String> {
        var names: Set<String> = []
        var splitter = CommentSplitter()
        for line in SourceText.lines(of: text) {
            let code = splitter.scan(line).code.trimmingCharacters(in: .whitespaces)
            guard code.hasPrefix("#") else { continue }
            let directive = code.dropFirst().trimmingCharacters(in: .whitespaces)
            for keyword in ["define", "undef"] where SourceText.startsWithKeyword(directive, keyword) {
                let rest = directive.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
                // A function-like macro's name stops at the open paren.
                let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { names.insert(String(name)) }
            }
        }
        return names
    }

    func selfDefinedMacros(in text: String) -> Set<String> {
        Self.selfDefinedMacrosImplementation(in: text)
    }

    // MARK: Prologue

    func buildPrologue(
        combos: [(name: String, value: Int)],
        members: [ShaderUniformDeclaration],
        emitFragmentOutput: Bool
    ) -> [String] {
        // Always 450: the body has been rewritten to core syntax, and pinning the version
        // here means a shader that declared an older one cannot contradict the rewrite.
        var lines = ["#version 450"]

        for combo in combos {
            lines.append("#define \(combo.name) \(combo.value)")
        }

        if !members.isEmpty {
            lines.append("layout(std140) uniform \(Self.uniformBlockName) {")
            for member in members {
                let suffix = member.arrayLength.map { "[\($0)]" } ?? ""
                lines.append("    \(member.type.rawValue) \(member.name)\(suffix);")
            }
            // No instance name, so members stay in global scope and the body needs no
            // rewriting to reach them.
            lines.append("};")
        }

        if emitFragmentOutput {
            lines.append("layout(location = 0) out vec4 \(Self.fragmentOutputName);")
        }

        return lines
    }

    // MARK: Body

    struct RewrittenBody {
        var lines: [String]
        var varyings: [String]
        var usesLegacyFragmentOutput: Bool
    }

    /// Rewrites the include-expanded source line by line.
    ///
    /// Exactly one output line per input line, so `lineMap` stays valid. Comments are dropped
    /// rather than carried through: they have already been mined for metadata, and keeping
    /// them would mean reconstructing block-comment delimiters the splitter has consumed.
    func rewriteBody(
        resolved: ResolvedShaderSource,
        stage: ShaderStage,
        shaderName: String,
        removingLines: Set<Int>,
        varyingLocations: [String: Int],
        diagnostics: inout [ShaderDiagnostic]
    ) -> RewrittenBody {
        var output: [String] = []
        var varyings: [String] = []
        var usesLegacyFragmentOutput = false
        var splitter = CommentSplitter()
        var blockDepth = 0
        var reportedLegacyQualifiers = false
        var sawVersion = false
        var nextFallbackLocation = 0

        for (offset, rawLine) in SourceText.lines(of: resolved.text).enumerated() {
            let lineNumber = offset + 1
            let scan = splitter.scan(rawLine)
            var code = scan.code
            let depthAtLineStart = blockDepth
            blockDepth += UniformAnnotationParser.braceDelta(in: code)

            if removingLines.contains(lineNumber) {
                // Gathered into the uniform block. A blank line keeps the mapping 1:1.
                output.append("")
                continue
            }

            let trimmed = code.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#") {
                let directive = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if SourceText.startsWithKeyword(directive, "version") {
                    sawVersion = true
                    // The prologue supplies the version; a second one is an error.
                    output.append("")
                    continue
                }
                if SourceText.startsWithKeyword(directive, "include") {
                    diagnostics.append(ShaderDiagnostic(
                        severity: .unsupported,
                        kind: .unresolvedInclude,
                        message: "An #include survived resolution and was removed.",
                        shaderName: shaderName,
                        line: lineNumber,
                        originFile: resolved.origin(ofLine: lineNumber)?.file
                    ))
                    output.append("")
                    continue
                }
            }

            if depthAtLineStart == 0, let varying = Self.varyingDeclaration(inCode: trimmed, stage: stage) {
                if varying.isLegacy, !reportedLegacyQualifiers {
                    reportedLegacyQualifiers = true
                    diagnostics.append(ShaderDiagnostic(
                        severity: .info,
                        kind: .legacyQualifiers,
                        message: "Legacy \"varying\"/\"attribute\" qualifiers were rewritten to \"in\"/\"out\".",
                        shaderName: shaderName,
                        line: lineNumber,
                        originFile: resolved.origin(ofLine: lineNumber)?.file
                    ))
                }
                // Only the ones carried between stages: a vertex attribute is bound through
                // the vertex descriptor, and a fragment output is a render target. Listing
                // those here would suggest the other stage has to match them.
                if varying.needsLocation, !varyings.contains(varying.name) {
                    varyings.append(varying.name)
                }

                // Only inputs and outputs carried between stages need matching locations;
                // a vertex attribute is bound by the vertex descriptor instead.
                if varying.needsLocation {
                    let location = varyingLocations[varying.name] ?? nextFallbackLocation
                    nextFallbackLocation = max(nextFallbackLocation, location + 1)
                    code = "layout(location = \(location)) " + varying.rewritten
                } else {
                    code = varying.rewritten
                }
                output.append(code)
                continue
            }

            let rewritten = rewriteFragmentOutput(
                in: Self.rewriteIdentifiers(in: code, using: Self.allIdentifierRewrites),
                stage: stage,
                shaderName: shaderName,
                line: lineNumber,
                originFile: resolved.origin(ofLine: lineNumber)?.file,
                diagnostics: &diagnostics
            )
            if rewritten.didRewrite { usesLegacyFragmentOutput = true }
            output.append(SourceText.trimmingTrailingWhitespace(rewritten.code))
        }

        if !sawVersion {
            diagnostics.append(ShaderDiagnostic(
                severity: .info,
                kind: .missingVersionDirective,
                message: "No #version directive; compiled as GLSL 450.",
                shaderName: shaderName
            ))
        }

        return RewrittenBody(
            lines: output, varyings: varyings, usesLegacyFragmentOutput: usesLegacyFragmentOutput
        )
    }

    // MARK: Varyings

    struct VaryingDeclaration {
        var name: String
        var rewritten: String
        var isLegacy: Bool
        /// False for vertex attributes, which the vertex descriptor binds by index.
        var needsLocation: Bool
        /// Set when the author wrote `layout(location = n)` themselves.
        var explicitLocation: Int?
    }

    /// Recognizes a stage input or output declaration and rewrites legacy spellings.
    ///
    /// Requires a `;` terminator and no parentheses, which is what tells `in vec3 x;` apart
    /// from the parameter qualifier in `void f(in vec3 x)`.
    static func varyingDeclaration(inCode code: String, stage: ShaderStage) -> VaryingDeclaration? {
        guard code.hasSuffix(";"), !code.contains("{") else { return nil }

        // An author-supplied `layout(location = ...)` is kept verbatim: they have already
        // decided the location, and replacing it could disagree with the other stage.
        let (explicitLayout, afterLayout) = SourceText.splitLeadingLayout(code)

        // Parentheses anywhere else mean this is a function signature, where `in` and `out`
        // are parameter qualifiers rather than declarations.
        guard !afterLayout.contains("(") else { return nil }

        // Interpolation qualifiers precede the storage qualifier.
        var prefix = explicitLayout.map { $0 + " " } ?? ""
        var rest = afterLayout
        let interpolation = ["flat", "smooth", "noperspective", "centroid", "sample"]
        var changed = true
        while changed {
            changed = false
            for qualifier in interpolation where SourceText.startsWithKeyword(rest, qualifier) {
                prefix += qualifier + " "
                rest = String(rest.dropFirst(qualifier.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }

        let keyword: String
        let replacement: String
        let isLegacy: Bool
        if SourceText.startsWithKeyword(rest, "varying") {
            keyword = "varying"
            replacement = stage == .vertex ? "out" : "in"
            isLegacy = true
        } else if SourceText.startsWithKeyword(rest, "attribute") {
            keyword = "attribute"
            replacement = "in"
            isLegacy = true
        } else if SourceText.startsWithKeyword(rest, "in") {
            keyword = "in"
            replacement = "in"
            isLegacy = false
        } else if SourceText.startsWithKeyword(rest, "out") {
            keyword = "out"
            replacement = "out"
            isLegacy = false
        } else {
            return nil
        }

        guard let declarator = UniformAnnotationParser.declarator(inCode: rest, keyword: keyword) else {
            return nil
        }

        let suffix = declarator.arrayLength.map { "[\($0)]" } ?? ""
        let rewritten = "\(prefix)\(replacement) \(declarator.typeName) \(declarator.name)\(suffix);"

        // A vertex shader's inputs are attributes: Metal binds them through the vertex
        // descriptor, and a fragment shader never sees them, so they need no shared location.
        // A fragment shader's outputs are render targets, already located by the prologue.
        let needsLocation = !(stage == .vertex && replacement == "in")
            && !(stage == .fragment && replacement == "out")

        return VaryingDeclaration(
            name: declarator.name,
            rewritten: rewritten,
            isLegacy: isLegacy,
            needsLocation: needsLocation && explicitLayout == nil,
            explicitLocation: explicitLayout.flatMap(Self.declaredLocation)
        )
    }

    /// What a stage's varyings look like before anything is rewritten.
    struct VaryingScan {
        /// Names needing a location assigned, in declaration order.
        var unlocated: [String]
        /// Locations the author assigned explicitly, which must not be handed out again.
        var reserved: Set<Int>
    }

    /// Reads the number out of `layout(location = 3)`.
    static func declaredLocation(in layout: String) -> Int? {
        guard let match = layout.firstMatch(of: /location\s*=\s*(\d+)/) else { return nil }
        return Int(match.1)
    }

    /// Varying names in declaration order, without doing the full rewrite.
    ///
    /// Used to build the shared location table before either stage is emitted.
    func varyingScan(of source: ShaderSource, provider: ShaderFileProvider) throws -> VaryingScan {
        let resolved: ResolvedShaderSource
        do {
            resolved = try includeResolver.resolve(source, provider: provider)
        } catch let error as IncludeError {
            throw ShaderPreprocessorError.includeFailed(error)
        }
        return Self.varyingScan(inText: resolved.text, stage: source.stage)
    }

    static func varyingScan(inText text: String, stage: ShaderStage) -> VaryingScan {
        var unlocated: [String] = []
        var reserved: Set<Int> = []
        var splitter = CommentSplitter()
        var blockDepth = 0

        for line in SourceText.lines(of: text) {
            let code = splitter.scan(line).code
            let depthAtLineStart = blockDepth
            blockDepth += UniformAnnotationParser.braceDelta(in: code)
            guard depthAtLineStart == 0 else { continue }
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            guard let varying = varyingDeclaration(inCode: trimmed, stage: stage) else { continue }

            if let explicit = varying.explicitLocation {
                reserved.insert(explicit)
                continue
            }
            guard varying.needsLocation else { continue }
            if !unlocated.contains(varying.name) { unlocated.append(varying.name) }
        }
        return VaryingScan(unlocated: unlocated, reserved: reserved)
    }

    /// Assigns each name the lowest location no one has claimed.
    static func assignLocations(to names: [String], avoiding reserved: Set<Int>) -> [String: Int] {
        var table: [String: Int] = [:]
        var next = 0
        for name in names {
            while reserved.contains(next) { next += 1 }
            table[name] = next
            next += 1
        }
        return table
    }

    // MARK: Identifiers

    /// Replaces whole identifier tokens using `table`.
    ///
    /// Token-wise rather than by substring so `texture2DLod` is never partly rewritten, and
    /// skipping identifiers after a `.` so a struct member named like a builtin is left alone.
    static func rewriteIdentifiers(in code: String, using table: [String: String]) -> String {
        guard !code.isEmpty else { return code }

        var output = ""
        output.reserveCapacity(code.count)
        var identifier = ""
        var previousMeaningful: Character?

        func flush() {
            guard !identifier.isEmpty else { return }
            if previousMeaningful == "." {
                output += identifier
            } else {
                output += table[identifier] ?? identifier
            }
            previousMeaningful = identifier.last
            identifier = ""
        }

        for character in code {
            if character.isLetter || character.isNumber || character == "_" {
                identifier.append(character)
                continue
            }
            flush()
            output.append(character)
            if !character.isWhitespace { previousMeaningful = character }
        }
        flush()
        return output
    }

    // MARK: Fragment output

    struct FragmentOutputRewrite {
        var code: String
        var didRewrite: Bool
    }

    /// Rewrites `gl_FragColor` and `gl_FragData[0]`, both removed from core GLSL.
    func rewriteFragmentOutput(
        in code: String,
        stage: ShaderStage,
        shaderName: String,
        line: Int,
        originFile: String?,
        diagnostics: inout [ShaderDiagnostic]
    ) -> FragmentOutputRewrite {
        guard stage == .fragment, code.contains("gl_Frag") else {
            return FragmentOutputRewrite(code: code, didRewrite: false)
        }

        var result = code
        var didRewrite = false

        if result.contains("gl_FragData") {
            // Multiple render targets would need one output per index and a pipeline that
            // declares them. Index 0 alone is the case shipped content uses.
            let pattern = /gl_FragData\s*\[\s*([0-9]+)\s*\]/
            var highestIndex = 0
            for match in result.matches(of: pattern) {
                highestIndex = max(highestIndex, Int(match.1) ?? 0)
            }
            if highestIndex > 0 {
                diagnostics.append(ShaderDiagnostic(
                    severity: .unsupported,
                    kind: .unrecognizedConstruct,
                    message: "This shader writes to gl_FragData[\(highestIndex)]; only a single render target is supported.",
                    shaderName: shaderName,
                    line: line,
                    originFile: originFile
                ))
            }
            result = result.replacing(pattern, with: Self.fragmentOutputName)
            didRewrite = true
        }

        if result.contains("gl_FragColor") {
            result = Self.rewriteIdentifiers(
                in: result, using: ["gl_FragColor": Self.fragmentOutputName]
            )
            didRewrite = true
        }

        return FragmentOutputRewrite(code: result, didRewrite: didRewrite)
    }
}
