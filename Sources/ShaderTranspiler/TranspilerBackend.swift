import Foundation
import ShaderBridge
import os

/// Translates preprocessed GLSL into Metal Shading Language.
public protocol TranspilerBackend: Sendable {
    func compileToMSL(glsl: String, stage: ShaderStage) throws -> String
}

public enum TranspilerBackendError: Error, LocalizedError, Equatable {
    case notVendored
    case translationFailed(stage: ShaderStage, detail: String)

    public var errorDescription: String? {
        switch self {
        case .notVendored:
            "The shader toolchain is not built. Run Scripts/vendor-shader-tools.sh."
        case .translationFailed(let stage, let detail):
            "Could not translate the \(stage.rawValue) shader: \(detail)"
        }
    }
}

/// Stand-in for builds where the toolchain has not been vendored.
///
/// Keeps everything upstream of the backend compilable and testable on a fresh clone, rather
/// than making a CMake build a precondition for `swift build`.
public struct UnavailableTranspilerBackend: TranspilerBackend {
    public init() {}

    public func compileToMSL(glsl: String, stage: ShaderStage) throws -> String {
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

    public func compileToMSL(glsl: String, stage: ShaderStage) throws -> String {
        var mslPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?

        let result = glsl.withCString { source in
            diorama_glsl_to_msl(
                source,
                stage == .vertex ? DioramaShaderStageVertex : DioramaShaderStageFragment,
                &mslPointer,
                &errorPointer
            )
        }

        // Both pointers are owned by the caller regardless of outcome.
        defer {
            if let mslPointer { diorama_shader_free(mslPointer) }
            if let errorPointer { diorama_shader_free(errorPointer) }
        }

        guard result == 0, let mslPointer else {
            let detail = errorPointer.map { String(cString: $0) }
                ?? "translation failed with code \(result)"
            throw TranspilerBackendError.translationFailed(stage: stage, detail: detail)
        }
        return String(cString: mslPointer)
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
            _ = try backend.compileToMSL(
                glsl: "#version 450\nvoid main() {}\n", stage: .fragment
            )
            return backend
        } catch {
            return UnavailableTranspilerBackend()
        }
    }
}
