import Foundation
import ShaderBridge
import os

// MARK: - Reflection

/// Where one resource landed in the translated shader's Metal binding space.
public struct ShaderResourceBinding: Sendable, Hashable, Codable {
    /// The GLSL name, e.g. `g_Texture0`.
    public var name: String
    /// The Metal slot: `[[texture(n)]]`, `[[sampler(n)]]` or `[[buffer(n)]]`.
    public var slot: Int

    public init(name: String, slot: Int) {
        self.name = name
        self.slot = slot
    }
}

/// Where one uniform block member landed, in bytes from the start of the block.
public struct ShaderMemberOffset: Sendable, Hashable, Codable {
    public var name: String
    public var offset: Int

    public init(name: String, offset: Int) {
        self.name = name
        self.offset = offset
    }
}

/// One shader input and the location it was assigned.
public struct ShaderStageInput: Sendable, Hashable, Codable {
    public var name: String
    public var location: Int

    /// Scalar components: 2 for a `vec2`, 3 for a `vec3`, and so on.
    ///
    /// A Metal vertex descriptor needs this to choose an attribute format, and by the time the
    /// shader is MSL the GLSL type that would have said so is gone.
    public var components: Int = 1

    public init(name: String, location: Int, components: Int = 1) {
        self.name = name
        self.location = location
        self.components = components
    }
}

/// What the translated shader expects, as reported by the translator rather than assumed.
///
/// SPIRV-Cross compacts Metal binding slots and drops resources the shader never reads, so
/// the second of two declared samplers becomes `[[texture(0)]]` when the first goes unused.
/// Binding by declaration order therefore swaps textures on any shader with an unused
/// sampler — which shipped content has, because combos switch samplers on and off. Everything
/// downstream binds by name through this table instead.
public struct ShaderReflection: Sendable, Hashable, Codable {
    /// The MSL entry point. SPIRV-Cross renames `main`, normally to `main0`.
    public var entryPoint: String
    public var buffers: [ShaderResourceBinding]

    /// Byte offsets of the uniform block's members, as the translator laid them out.
    ///
    /// `UniformBlockLayout` computes the same offsets from the std140 rules without needing
    /// the toolchain. Having both means the agreement between them is a checked invariant
    /// rather than an assumption — and it is the assumption every uniform write depends on.
    public var members: [ShaderMemberOffset] = []
    public var textures: [ShaderResourceBinding]
    public var samplers: [ShaderResourceBinding]
    public var inputs: [ShaderStageInput]

    public init(
        entryPoint: String,
        buffers: [ShaderResourceBinding] = [],
        members: [ShaderMemberOffset] = [],
        textures: [ShaderResourceBinding] = [],
        samplers: [ShaderResourceBinding] = [],
        inputs: [ShaderStageInput] = []
    ) {
        self.entryPoint = entryPoint
        self.buffers = buffers
        self.members = members
        self.textures = textures
        self.samplers = samplers
        self.inputs = inputs
    }

    public func textureSlot(for name: String) -> Int? {
        textures.first { $0.name == name }?.slot
    }

    public func samplerSlot(for name: String) -> Int? {
        samplers.first { $0.name == name }?.slot
    }

    /// The slot of the gathered uniform block, when the shader kept it.
    ///
    /// Absent when every uniform was eliminated as unused, in which case there is no buffer
    /// to bind and nothing to report.
    public func bufferSlot(for name: String) -> Int? {
        buffers.first { $0.name == name }?.slot
    }

    /// The highest Metal buffer index the shader occupies, or `nil` when it uses none.
    ///
    /// Vertex attribute buffers share `[[buffer(n)]]` with constant buffers, so the vertex
    /// pipeline has to place its attribute buffer above this.
    public var highestBufferSlot: Int? { buffers.map(\.slot).max() }
}

/// A translated shader and its binding contract.
public struct TranspiledShader: Sendable, Hashable, Codable {
    public var msl: String
    public var reflection: ShaderReflection

    public init(msl: String, reflection: ShaderReflection) {
        self.msl = msl
        self.reflection = reflection
    }
}

// MARK: - Backend

/// Translates preprocessed GLSL into Metal Shading Language.
public protocol TranspilerBackend: Sendable {
    func compile(glsl: String, stage: ShaderStage) throws -> TranspiledShader
}

public extension TranspilerBackend {
    /// The translated source alone, for callers that only want to read it.
    func compileToMSL(glsl: String, stage: ShaderStage) throws -> String {
        try compile(glsl: glsl, stage: stage).msl
    }
}

public enum TranspilerBackendError: Error, LocalizedError, Equatable {
    case notVendored
    case translationFailed(stage: ShaderStage, detail: String)
    case malformedReflection(detail: String)

    public var errorDescription: String? {
        switch self {
        case .notVendored:
            "The shader toolchain is not built. Run Scripts/vendor-shader-tools.sh."
        case .translationFailed(let stage, let detail):
            "Could not translate the \(stage.rawValue) shader: \(detail)"
        case .malformedReflection(let detail):
            "The translated shader's binding description could not be read: \(detail)"
        }
    }
}

/// Stand-in for builds where the toolchain has not been vendored.
///
/// Keeps everything upstream of the backend compilable and testable on a fresh clone, rather
/// than making a CMake build a precondition for `swift build`.
public struct UnavailableTranspilerBackend: TranspilerBackend {
    public init() {}

    public func compile(glsl: String, stage: ShaderStage) throws -> TranspiledShader {
        throw TranspilerBackendError.notVendored
    }
}

/// GLSL to MSL via glslang and SPIRV-Cross.
///
/// The same route MoltenVK takes — GLSL to SPIR-V to MSL — without the Vulkan runtime in
/// between. PLAN.md §5.4 argues for going straight to Metal rather than shipping MoltenVK; this
/// is what that means in practice, and it happens once at import rather than per frame.
public struct GlslangTranspilerBackend: TranspilerBackend {
    private let log = Logger(subsystem: "app.diorama", category: "transpile")

    public init() {
        diorama_shader_bridge_initialize()
    }

    public func compile(glsl: String, stage: ShaderStage) throws -> TranspiledShader {
        var mslPointer: UnsafeMutablePointer<CChar>?
        var reflectionPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?

        let result = glsl.withCString { source in
            diorama_glsl_to_msl(
                source,
                stage == .vertex ? DioramaShaderStageVertex : DioramaShaderStageFragment,
                &mslPointer,
                &reflectionPointer,
                &errorPointer
            )
        }

        // Every out-pointer is owned by the caller regardless of outcome.
        defer {
            if let mslPointer { diorama_shader_free(mslPointer) }
            if let reflectionPointer { diorama_shader_free(reflectionPointer) }
            if let errorPointer { diorama_shader_free(errorPointer) }
        }

        guard result == 0, let mslPointer else {
            let detail = errorPointer.map { String(cString: $0) }
                ?? "translation failed with code \(result)"
            throw TranspilerBackendError.translationFailed(stage: stage, detail: detail)
        }

        guard let reflectionPointer else {
            throw TranspilerBackendError.malformedReflection(detail: "the translator reported none")
        }
        let reflectionJSON = String(cString: reflectionPointer)
        let reflection: ShaderReflection
        do {
            reflection = try JSONDecoder().decode(
                ShaderReflection.self, from: Data(reflectionJSON.utf8)
            )
        } catch {
            throw TranspilerBackendError.malformedReflection(detail: String(describing: error))
        }

        return TranspiledShader(msl: String(cString: mslPointer), reflection: reflection)
    }
}

/// The backend to use, chosen at runtime.
///
/// Falls back rather than failing so a build without the vendored toolchain still runs; the
/// shaders simply report as unavailable through the usual compatibility path instead of taking
/// the app down.
public enum TranspilerBackendFactory {
    public static func makeDefault() -> any TranspilerBackend {
        let backend = GlslangTranspilerBackend()
        // Probe with the smallest legal shader. If the toolchain is missing or mislinked this
        // surfaces here, once, rather than on the first wallpaper someone opens.
        do {
            _ = try backend.compile(glsl: "#version 450\nvoid main() {}\n", stage: .fragment)
            return backend
        } catch {
            return UnavailableTranspilerBackend()
        }
    }
}
