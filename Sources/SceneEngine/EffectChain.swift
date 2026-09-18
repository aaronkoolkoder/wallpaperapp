import Diagnostics
import Foundation
import Metal
import MetalRenderer
import ShaderTranspiler
import WEFormat
import simd
import os

/// Where one of an effect pass's sampler slots reads from.
public enum EffectInput: @unchecked Sendable {
    /// Whatever the chain was handed: the isolated layer, or the composited frame.
    case chainInput
    /// A target written by an earlier pass of the same chain.
    case renderTarget(String)
    /// A texture from the wallpaper's own assets, such as a noise or gradient lookup.
    case texture(any MTLTexture)
}

/// One pass of an effect, compiled.
public struct CompiledEffectPass: @unchecked Sendable {
    public var program: MaterialProgram
    /// Named target this pass writes, or nil for the chain's output.
    public var target: String?
    /// Sampler slot to its source. Slots are the shader's declaration order, which is what a
    /// `bind` entry's `index` refers to.
    public var inputs: [Int: EffectInput]
    public var constants: [String: DynamicValue]
}

/// An effect whose own shaders will run, rather than a built-in approximation of it.
public struct CompiledEffect: @unchecked Sendable {
    public var name: String
    public var passes: [CompiledEffectPass]
}

/// One step of a layer's or scene's effect chain.
///
/// Mixed on purpose: an effect whose shaders compiled runs as the author wrote it, while one
/// that could not falls back to a built-in approximation. Keeping both in one ordered list is
/// what preserves the author's order across the two kinds — running all the compiled ones and
/// then all the approximations would change the result of any chain that mixes them.
public enum LayerEffect: @unchecked Sendable {
    case compiled(CompiledEffect)
    case builtIn(PostEffect)

    public var debugName: String {
        switch self {
        case .compiled(let effect): effect.name
        case .builtIn(let effect): effect.debugName
        }
    }

    public var isCompiled: Bool {
        if case .compiled = self { return true }
        return false
    }
}

public extension Array where Element == LayerEffect {
    /// The approximated steps only, for paths that cannot run compiled chains.
    var builtInOnly: [PostEffect] {
        compactMap { step in
            if case .builtIn(let effect) = step { return effect }
            return nil
        }
    }
}

/// Runs compiled effect chains.
///
/// The built-in `PostProcessor` remains for effects that could not be compiled — it approximates
/// six common ones by name, which is what the whole app did before the transpiler. This runs the
/// author's actual passes instead: their own shaders, their own intermediate targets, in their
/// own order.
public final class EffectChainRunner {
    private let materials: MaterialRenderer
    private let log = Logger(subsystem: "app.diorama", category: "effect")

    public init(materials: MaterialRenderer) {
        self.materials = materials
    }

    /// A full-screen quad in clip space.
    ///
    /// The unit quad the material path draws spans -0.5 to 0.5, so doubling it covers the
    /// target exactly. Effect shaders read their position through the same
    /// `g_ModelViewProjection` a layer's shader does, so there is nothing special to bind.
    public static let fullscreenTransform = simd_float4x4(diagonal: SIMD4(2, 2, 1, 1))

    /// Runs `effect`, reading `source` and leaving the result in `destination`.
    ///
    /// Returns false when the chain could not run, so the caller can fall back rather than
    /// leaving the destination undefined.
    @discardableResult
    public func run(
        _ effect: CompiledEffect,
        source: any MTLTexture,
        destination: any MTLTexture,
        overrides: [String: DynamicValue] = [:],
        engine: EngineUniforms,
        commandBuffer: any MTLCommandBuffer,
        pool: FBOPool
    ) -> Bool {
        guard !effect.passes.isEmpty else { return false }

        var targets: [String: PooledTexture] = [:]
        defer { for pooled in targets.values { pool.release(pooled) } }

        for (index, pass) in effect.passes.enumerated() {
            let isLast = index == effect.passes.count - 1

            // A pass naming no target writes the chain's output; so does the final pass, whose
            // target — if it names one — nothing downstream will read.
            let output: any MTLTexture
            if isLast {
                output = destination
            } else if let name = pass.target {
                guard let pooled = targets[name] ?? pool.acquire(
                    width: destination.width,
                    height: destination.height,
                    pixelFormat: destination.pixelFormat
                ) else {
                    log.error("no target available for \(effect.name, privacy: .public)")
                    return false
                }
                targets[name] = pooled
                output = pooled.texture
            } else {
                output = destination
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = output
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: 0, green: 0, blue: 0, alpha: 0
            )
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return false }

            var textures: [String: any MTLTexture] = [:]
            for (slot, name) in pass.program.declaredSamplers.enumerated() {
                switch pass.inputs[slot] {
                case .texture(let texture):
                    textures[name] = texture
                case .renderTarget(let target):
                    // A target not yet written is the chain's own input. Wallpaper Engine
                    // supplies several such names itself (`_rt_FullFrameBuffer` and friends);
                    // treating an unwritten one as the input is what makes a single-pass effect
                    // read the layer it is applied to.
                    // TODO(verify): against real Workshop effects, which of the engine's
                    // reserved target names mean something other than "the frame so far".
                    textures[name] = targets[target]?.texture ?? source
                case .chainInput:
                    textures[name] = source
                case .none:
                    // An unbound first slot is the input; anything further is genuinely unbound
                    // and gets the renderer's placeholder.
                    if slot == 0 { textures[name] = source }
                }
            }

            var passEngine = engine
            passEngine.screenSize = SIMD2(Float(output.width), Float(output.height))

            materials.encode(
                pass.program,
                context: MaterialRenderer.DrawContext(
                    transform: Self.fullscreenTransform,
                    projection: matrix_identity_float4x4,
                    textures: textures,
                    constants: pass.constants,
                    overrides: overrides,
                    engine: passEngine
                ),
                into: encoder
            )
            encoder.endEncoding()
        }
        return true
    }
}

// MARK: - Compilation

extension MaterialCompiler {
    /// Compiles an effect's passes, or returns nil when it cannot be run faithfully.
    ///
    /// Returning nil rather than a partial chain is deliberate: half an effect looks like a
    /// rendering bug, while the built-in approximation the caller falls back to at least looks
    /// like the effect it is named after.
    public func effect(
        for document: EffectDocument,
        assets: SceneAssets,
        device: any MTLDevice,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        report: inout CompatibilityReport
    ) -> CompiledEffect? {
        guard isAvailable, !document.passes.isEmpty else { return nil }
        let name = document.name ?? "effect"

        var compiled: [CompiledEffectPass] = []
        for (index, pass) in document.passes.enumerated() {
            guard let materialPath = pass.material,
                  let material = assets.material(at: materialPath),
                  let materialPass = material.firstPass
            else {
                report.add(
                    .degraded, feature: "Effect",
                    detail: "\(name): pass \(index + 1) names no usable material"
                )
                return nil
            }

            // The effect's own combos and constants layer over the material's.
            var merged = materialPass
            merged.combos.merge(pass.combos) { _, effectValue in effectValue }

            let program: MaterialProgram
            do {
                program = try self.program(for: merged, assets: assets, pixelFormat: pixelFormat)
            } catch {
                report.add(
                    .degraded, feature: "Effect",
                    detail: "\(name): \(ShaderMessageText.oneLine(error.localizedDescription))"
                )
                return nil
            }

            var inputs: [Int: EffectInput] = [:]
            for binding in pass.bindings {
                if binding.isRenderTarget {
                    inputs[binding.index] = .renderTarget(binding.name)
                } else if let texture = assets.texture(at: binding.name, device: device) {
                    inputs[binding.index] = .texture(texture)
                } else {
                    report.add(
                        .degraded, feature: "Effect",
                        detail: "\(name): texture \(binding.name) is missing"
                    )
                }
            }

            var constants = materialPass.constantShaderValues
            constants.merge(pass.constantShaderValues) { _, effectValue in effectValue }

            compiled.append(CompiledEffectPass(
                program: program, target: pass.target, inputs: inputs, constants: constants
            ))
        }

        return CompiledEffect(name: name, passes: compiled)
    }
}
