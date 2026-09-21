import Diagnostics
import Foundation
import Metal
import MetalRenderer
import ShaderTranspiler
import WEFormat
import os

/// Reads shader source out of a wallpaper's assets.
///
/// Wallpaper Engine keeps shaders under `shaders/` and writes includes relative to it, so
/// `#include "common.h"` means `shaders/common.h`. Paths are tried with and without the
/// prefix because material `shader` fields are written both ways.
///
/// `@unchecked Sendable` because `SceneAssets` is a class with mutable caches. The escape is
/// narrow rather than blanket: this provider is created, used and discarded inside a single
/// `program(for:)` call on the render queue, and the only method it calls — `data(for:)` — reads
/// the archive without touching either the texture cache or the report.
struct SceneAssetShaderProvider: ShaderFileProvider, @unchecked Sendable {
    let assets: SceneAssets

    func contents(of name: String) throws -> String {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        var candidates = [normalized]
        if !normalized.hasPrefix("shaders/") {
            candidates.append("shaders/" + normalized)
        }

        for candidate in candidates {
            if let data = assets.data(for: candidate),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }

        throw ShaderFileProviderError.notFound(name)
    }
}

/// A material pass compiled into something that can be drawn.
public struct MaterialProgram: @unchecked Sendable {
    public var name: String
    public var pipeline: any MTLRenderPipelineState

    /// Constant buffer layouts, per stage. Either can be empty.
    public var vertexLayout: UniformBlockLayout
    public var fragmentLayout: UniformBlockLayout

    /// Where each stage's constant buffer binds, when it has one.
    public var vertexBufferSlot: Int?
    public var fragmentBufferSlot: Int?

    /// Uniform declarations per stage, carrying the defaults and material keys.
    public var vertexUniforms: [ShaderUniformDeclaration]
    public var fragmentUniforms: [ShaderUniformDeclaration]

    /// Sampler name to the Metal texture slot it was actually assigned.
    public var textureSlots: [String: Int]
    public var samplerSlots: [String: Int]

    /// Sampler names in the order the shader declares them, which is how a material's
    /// `textures` array is matched up: entry *n* feeds `g_TextureN`.
    public var declaredSamplers: [String]

    /// Each sampler's `default` texture from its annotation — `util/noflow`, `util/white` —
    /// which is what it reads when nothing else assigns it one.
    public var samplerDefaults: [String: String] = [:]

    /// Unit-quad geometry laid out for this shader's own attributes.
    public var vertexBuffer: any MTLBuffer
    public var vertexBufferIndex: Int
    public var vertexCount: Int

    public var diagnostics: [ShaderDiagnostic]
}

public enum MaterialProgramError: Error, LocalizedError {
    case noShaderNamed
    case stageMissing(String)
    case pipelineFailed(String)
    case geometryFailed

    /// What the preprocessor found before the failure.
    ///
    /// Carried with the error because it is usually the actionable half. A shader with an
    /// unreadable uniform declaration fails in the backend with "non-opaque uniforms outside a
    /// block", which describes a rule the author never wrote against; the preprocessor already
    /// knows it could not read line 3, and that is what the report should say.
    public var diagnostics: [ShaderDiagnostic] {
        if case .shaderFailed(_, let diagnostics) = self { return diagnostics }
        return []
    }

    case shaderFailed(detail: String, diagnostics: [ShaderDiagnostic])

    public var errorDescription: String? {
        switch self {
        case .noShaderNamed: "The material pass names no shader."
        case .stageMissing(let name): "Shader \"\(name)\" is missing a stage."
        case .pipelineFailed(let detail): "The Metal pipeline could not be built: \(detail)"
        case .geometryFailed: "Quad geometry could not be allocated."
        case .shaderFailed(let detail, _): detail
        }
    }
}

/// Compiles Wallpaper Engine material passes into Metal pipelines.
///
/// This is what closes PLAN.md §5.4: up to here effects were matched by name against built-in
/// approximations, which covers the common ones and silently flattens everything else. Running
/// the author's own shader is the difference between a wallpaper that looks like itself and one
/// that looks close.
public final class MaterialCompiler {
    private let device: any MTLDevice
    private let backend: any TranspilerBackend
    private let cache: ShaderCache
    private let preprocessor = ShaderPreprocessor()
    private let log = Logger(subsystem: "app.diorama", category: "material")

    /// Keyed by the *content* of both preprocessed stages plus the pipeline state, never by
    /// shader name. Two wallpapers routinely ship different shaders both called
    /// `genericimage2`, so a name-keyed cache would hand the second one the first one's
    /// pipeline — and a compiler shared across a library is exactly what auditing one wants.
    private var programs: [String: MaterialProgram] = [:]

    /// Insertion order, for eviction. A plain array because the cap is small enough that the
    /// scan costs less than maintaining a linked list would.
    private var programOrder: [String] = []

    /// How many compiled programs to hold.
    ///
    /// Each one owns a Metal pipeline and a vertex buffer. A single wallpaper needs a handful,
    /// but one compiler audits a whole library — `wetool report` over a few hundred Workshop
    /// items would otherwise accumulate thousands and balloon. Rebuilding an evicted one from
    /// its already-translated MSL costs a few milliseconds, since the translation cache below
    /// still has it.
    public static let defaultProgramLimit = 256

    private let programLimit: Int

    public init(
        device: any MTLDevice,
        backend: (any TranspilerBackend)? = nil,
        cache: ShaderCache = ShaderCache(),
        programLimit: Int = MaterialCompiler.defaultProgramLimit
    ) {
        self.device = device
        self.backend = backend ?? TranspilerBackendFactory.makeDefault()
        self.cache = cache
        self.programLimit = max(1, programLimit)
    }

    /// True when shaders can actually be translated in this build.
    public var isAvailable: Bool { !(backend is UnavailableTranspilerBackend) }

    public func program(
        for pass: MaterialPass,
        assets: SceneAssets,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
    ) throws -> MaterialProgram {
        guard let shaderName = pass.shader, !shaderName.isEmpty else {
            throw MaterialProgramError.noShaderNamed
        }

        let provider = SceneAssetShaderProvider(assets: assets)
        let vertexText = try provider.contents(of: shaderName + ".vert")
        let fragmentText = try provider.contents(of: shaderName + ".frag")

        // Every slot the material names a texture for. A sampler annotated with a combo —
        // `{"combo":"MASK"}` — switches that combo on when its slot is filled, which is what
        // compiles the code that reads it.
        let boundTextures = Set(pass.textures.enumerated().compactMap { slot, path in
            (path?.isEmpty == false) ? slot : nil
        })
        let (vertex, fragment) = try preprocessor.preprocessPair(
            vertex: ShaderSource(name: shaderName + ".vert", stage: .vertex, text: vertexText),
            fragment: ShaderSource(name: shaderName + ".frag", stage: .fragment, text: fragmentText),
            provider: provider,
            comboOverrides: pass.combos,
            boundTextures: boundTextures
        )

        // Preprocessing is string work measured in microseconds and happens at import, so
        // paying for it before the cache lookup costs nothing and buys a key that cannot
        // collide.
        let key = Self.cacheKey(
            vertex: vertex, fragment: fragment, pass: pass, pixelFormat: pixelFormat
        )
        if let existing = programs[key] {
            // Touched, so a program in active use is not the one evicted next.
            if let position = programOrder.firstIndex(of: key) {
                programOrder.remove(at: position)
                programOrder.append(key)
            }
            return existing
        }

        var diagnostics = vertex.diagnostics + fragment.diagnostics

        let vertexShader: TranspiledShader
        let fragmentShader: TranspiledShader
        do {
            vertexShader = try cache.shader(for: vertex, backend: backend, diagnostics: &diagnostics)
            fragmentShader = try cache.shader(for: fragment, backend: backend, diagnostics: &diagnostics)
        } catch {
            // Remapped to the author's own line numbers: the prologue shifted everything and
            // includes were flattened, so the raw number names a line nobody can open.
            throw MaterialProgramError.shaderFailed(
                detail: Self.remap(error, vertex: vertex, fragment: fragment),
                diagnostics: diagnostics
            )
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "material-\(shaderName)"
        descriptor.vertexFunction = try function(
            named: vertexShader.reflection.entryPoint, source: vertexShader.msl, stage: "vertex"
        )
        descriptor.fragmentFunction = try function(
            named: fragmentShader.reflection.entryPoint, source: fragmentShader.msl, stage: "fragment"
        )
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        SceneBuilder.materialBlendMode(named: pass.blending)
            .apply(to: descriptor.colorAttachments[0])

        // Metal shares one index space between vertex attribute buffers and constant buffers,
        // so the geometry has to go above whatever the shader's own uniform blocks took.
        let vertexBufferIndex = (vertexShader.reflection.highestBufferSlot ?? -1) + 1
        let geometry = try quadGeometry(
            for: vertexShader.reflection.inputs,
            bufferIndex: vertexBufferIndex,
            descriptor: descriptor,
            shaderName: shaderName,
            diagnostics: &diagnostics
        )

        let pipeline: any MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MaterialProgramError.pipelineFailed(error.localizedDescription)
        }

        let program = MaterialProgram(
            name: shaderName,
            pipeline: pipeline,
            vertexLayout: vertex.layout,
            fragmentLayout: fragment.layout,
            vertexBufferSlot: vertexShader.reflection.bufferSlot(for: ShaderPreprocessor.uniformBlockName),
            fragmentBufferSlot: fragmentShader.reflection.bufferSlot(for: ShaderPreprocessor.uniformBlockName),
            vertexUniforms: vertex.uniforms,
            fragmentUniforms: fragment.uniforms,
            textureSlots: Dictionary(
                fragmentShader.reflection.textures.map { ($0.name, $0.slot) },
                uniquingKeysWith: { first, _ in first }
            ),
            samplerSlots: Dictionary(
                fragmentShader.reflection.samplers.map { ($0.name, $0.slot) },
                uniquingKeysWith: { first, _ in first }
            ),
            declaredSamplers: fragment.samplers.map(\.name),
            samplerDefaults: Dictionary(
                fragment.samplers.compactMap { sampler -> (String, String)? in
                    guard case .texture(let path)? = sampler.defaultValue, !path.isEmpty else {
                        return nil
                    }
                    return (sampler.name, path)
                },
                uniquingKeysWith: { first, _ in first }
            ),
            vertexBuffer: geometry.buffer,
            vertexBufferIndex: vertexBufferIndex,
            vertexCount: geometry.count,
            diagnostics: diagnostics
        )
        store(program, for: key)
        return program
    }

    private func store(_ program: MaterialProgram, for key: String) {
        programs[key] = program
        programOrder.append(key)

        while programOrder.count > programLimit {
            let oldest = programOrder.removeFirst()
            programs.removeValue(forKey: oldest)
        }
    }

    public var compiledProgramCount: Int { programs.count }

    // MARK: - Pipeline pieces

    private func function(
        named name: String, source: String, stage: String
    ) throws -> any MTLFunction {
        // Compiled from source at runtime rather than from a .metallib: this MSL did not exist
        // at build time, and `xcrun metal` is not available inside the App Store sandbox.
        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw MaterialProgramError.pipelineFailed(
                "the \(stage) shader did not compile: \(error.localizedDescription)"
            )
        }
        guard let function = library.makeFunction(name: name) else {
            throw MaterialProgramError.stageMissing(name)
        }
        return function
    }

    /// Builds unit-quad geometry in whatever layout this shader's attributes ask for.
    ///
    /// Interleaved into one buffer laid out to match the shader rather than a fixed struct, so
    /// a shader that reads only a position is not made to carry texture coordinates, and one
    /// that reads an attribute we have no meaning for still gets something defined.
    private func quadGeometry(
        for inputs: [ShaderStageInput],
        bufferIndex: Int,
        descriptor: MTLRenderPipelineDescriptor,
        shaderName: String,
        diagnostics: inout [ShaderDiagnostic]
    ) throws -> (buffer: any MTLBuffer, count: Int) {
        let attributes = inputs.sorted { $0.location < $1.location }
        let vertexDescriptor = MTLVertexDescriptor()

        var offset = 0
        var vertices: [[Float]] = Array(repeating: [], count: Self.quadVertexCount)

        for attribute in attributes {
            guard let format = Self.format(components: attribute.components) else {
                diagnostics.append(ShaderDiagnostic(
                    severity: .degraded,
                    kind: .unrecognizedConstruct,
                    message: "Vertex attribute \"\(attribute.name)\" has \(attribute.components) components, which has no Metal equivalent.",
                    shaderName: shaderName
                ))
                continue
            }

            vertexDescriptor.attributes[attribute.location].format = format
            vertexDescriptor.attributes[attribute.location].offset = offset
            vertexDescriptor.attributes[attribute.location].bufferIndex = bufferIndex

            let values = Self.quadValues(for: attribute.name, components: attribute.components)
            if values == nil {
                // Zero-filled rather than left undefined: an unknown attribute should make the
                // layer look wrong in a stable way, not sample uninitialised memory.
                diagnostics.append(ShaderDiagnostic(
                    severity: .degraded,
                    kind: .unrecognizedConstruct,
                    message: "Vertex attribute \"\(attribute.name)\" has no known meaning and was filled with zeroes.",
                    shaderName: shaderName
                ))
            }
            let resolved = values ?? Array(
                repeating: [Float](repeating: 0, count: attribute.components),
                count: Self.quadVertexCount
            )
            for index in 0 ..< Self.quadVertexCount {
                vertices[index].append(contentsOf: resolved[index])
            }
            offset += attribute.components * MemoryLayout<Float>.size
        }

        // A shader with no attributes at all generates its own geometry; give it a token
        // buffer so the binding code has one shape to deal with.
        let stride = max(offset, MemoryLayout<Float>.size)
        vertexDescriptor.layouts[bufferIndex].stride = stride
        vertexDescriptor.layouts[bufferIndex].stepFunction = .perVertex
        if offset > 0 { descriptor.vertexDescriptor = vertexDescriptor }

        let flattened = vertices.flatMap { $0 }
        let bytes = max(flattened.count * MemoryLayout<Float>.size, stride)
        guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw MaterialProgramError.geometryFailed
        }
        if !flattened.isEmpty {
            flattened.withUnsafeBytes { raw in
                buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }
        buffer.label = "quad-\(shaderName)"
        return (buffer, Self.quadVertexCount)
    }

    static let quadVertexCount = 4

    static func format(components: Int) -> MTLVertexFormat? {
        switch components {
        case 1: .float
        case 2: .float2
        case 3: .float3
        case 4: .float4
        default: nil
        }
    }

    /// Per-vertex values for the attribute names Wallpaper Engine uses.
    ///
    /// Triangle-strip order — bottom-left, bottom-right, top-left, top-right — matching the
    /// built-in quad renderer, so a scene that mixes materials with and without custom shaders
    /// does not flip half its layers.
    static func quadValues(for name: String, components: Int) -> [[Float]]? {
        let corners: [[Float]] = [[-0.5, -0.5, 0], [0.5, -0.5, 0], [-0.5, 0.5, 0], [0.5, 0.5, 0]]
        let texCoords: [[Float]] = [[0, 1], [1, 1], [0, 0], [1, 0]]

        let base: [[Float]]
        switch name.lowercased() {
        case "a_position", "a_positionvertex", "in_position":
            base = corners
        case "a_texcoord", "a_texcoord0", "a_uv", "in_texcoord":
            base = texCoords
        case "a_texcoordvec4":
            // Some shaders take two coordinate sets packed into one attribute.
            base = texCoords.map { $0 + $0 }
        case "a_normal":
            base = Array(repeating: [0, 0, 1], count: quadVertexCount)
        case "a_color", "a_colour", "a_color0":
            base = Array(repeating: [1, 1, 1, 1], count: quadVertexCount)
        default:
            return nil
        }

        return base.map { value in
            var padded = Array(value.prefix(components))
            while padded.count < components {
                // Pad a position with w = 1 and anything else with 0, which is what the
                // equivalent GLSL constructor would do.
                padded.append(padded.count == 3 && base[0].count >= 3 ? 1 : 0)
            }
            return padded
        }
    }

    /// The source hashes already cover the combo values, since the combo defines are part of
    /// the emitted GLSL that was hashed. Blend and pixel format are not in the shader at all
    /// but do change the pipeline, so they are named here.
    /// Rewrites `0:37:` in a backend message to the file and line the author wrote.
    static func remap(
        _ error: any Error, vertex: PreprocessedShader, fragment: PreprocessedShader
    ) -> String {
        guard case TranspilerBackendError.translationFailed(let stage, let detail) = error else {
            return error.localizedDescription
        }
        let shader = stage == .vertex ? vertex : fragment
        let pattern = /0:(\d+):/
        return detail.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let match = line.firstMatch(of: pattern),
                  let emitted = Int(match.1),
                  let origin = shader.origin(ofEmittedLine: emitted)
            else { return String(line) }
            return String(line.replacing(pattern, with: "\(origin.file):\(origin.line):"))
        }.joined(separator: "\n")
    }

    static func cacheKey(
        vertex: PreprocessedShader,
        fragment: PreprocessedShader,
        pass: MaterialPass,
        pixelFormat: MTLPixelFormat
    ) -> String {
        "\(vertex.sourceHash)|\(fragment.sourceHash)|\(pass.blending ?? "normal")|\(pixelFormat.rawValue)"
    }
}

/// Flattens a compiler's multi-line output into something a report can list.
///
/// glslang answers with several lines, often with a blank one and a trailing summary. Dropped
/// verbatim into a findings list it breaks the layout and buries every finding after it, so the
/// first real line is kept and the rest is counted.
enum ShaderMessageText {
    static let limit = 160

    static func oneLine(_ text: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let first = lines.first else { return text }

        // "parse failed:" on its own says nothing; the line after it is the actual error.
        var head = first
        var rest = lines.dropFirst()
        if head.hasSuffix(":"), let next = rest.first {
            head += " " + next
            rest = rest.dropFirst()
        }

        // The trailing "N compilation errors" line repeats what the count already says.
        let remaining = rest.filter { !$0.lowercased().contains("compilation error") }
        if !remaining.isEmpty {
            head += " (+\(remaining.count) more)"
        }
        return head.count > limit ? String(head.prefix(limit - 1)) + "…" : head
    }
}

/// Vends a compiler per wallpaper over one long-lived translation cache.
///
/// The two have deliberately different lifetimes, and getting them the same way round is a
/// mistake in either direction. The cache should outlive individual wallpapers: translation is
/// the expensive half, and paying for it again every time a playlist comes back round to a
/// wallpaper is waste. The compiler should not: it holds a Metal pipeline and a vertex buffer
/// per material, and keeping those for every wallpaper a playlist has ever shown grows without
/// bound over a long session. Rebuilding a pipeline from already-translated MSL costs a few
/// milliseconds on the switch path, where a brief transition is expected anyway.
public final class MaterialCompilerFactory {
    private let cache: ShaderCache

    public init(cache: ShaderCache = ShaderCache()) {
        self.cache = cache
    }

    public func makeCompiler(device: any MTLDevice) -> MaterialCompiler {
        MaterialCompiler(device: device, cache: cache)
    }
}
