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
    /// A texture from the wallpaper's own assets, such as a noise or gradient lookup. Kept with
    /// its image size, because a padded mask would otherwise report its allocation to
    /// `g_TextureNResolution` and be sampled past its edge.
    case texture(SceneTexture)
}

/// One pass of an effect, compiled.
public struct CompiledEffectPass: @unchecked Sendable {
    public var program: MaterialProgram
    /// Named target this pass writes, or nil for the chain's output.
    public var target: String?
    /// Texture index to its source, where index `N` is the sampler named `g_TextureN`.
    ///
    /// Not the shader's declaration order. A `bind` entry's `index` names the sampler by
    /// number — `blur_combine.frag` annotates `g_Texture2` as `previous` and its pass binds
    /// `previous` at index 2 — and the two part company as soon as a combo leaves a sampler
    /// undeclared, which would shift every later binding onto the wrong texture.
    public var inputs: [Int: EffectInput]
    public var constants: [String: DynamicValue]
}

/// An effect whose own shaders will run, rather than a built-in approximation of it.
public struct CompiledEffect: @unchecked Sendable {
    public var name: String
    public var passes: [CompiledEffectPass]
    /// Output-size divisor for each named target the effect declares; absent means full size.
    public var targetScales: [String: Int] = [:]
}

/// One step of a layer's or scene's effect chain.
///
/// Mixed on purpose: an effect whose shaders compiled runs as the author wrote it, while one
/// that could not falls back to a built-in approximation. Keeping both in one ordered list is
/// what preserves the author's order across the two kinds — running all the compiled ones and
/// then all the approximations would change the result of any chain that mixes them.
public struct LayerEffect: @unchecked Sendable {
    public enum Implementation {
        case compiled(CompiledEffect)
        case builtIn(PostEffect)
    }

    public var implementation: Implementation

    /// Nil for an effect that always runs. Otherwise the effect is tied to one of the
    /// wallpaper's user properties and runs only while that property says so — the author's
    /// way of shipping an optional effect, often switched off by default. Evaluated every
    /// frame, so changing the property in the inspector takes effect without a reload.
    public var visibility: SceneVisibility?

    public init(_ implementation: Implementation, visibility: SceneVisibility? = nil) {
        self.implementation = implementation
        self.visibility = visibility
    }

    public static func compiled(_ effect: CompiledEffect) -> LayerEffect {
        LayerEffect(.compiled(effect))
    }

    public static func builtIn(_ effect: PostEffect) -> LayerEffect {
        LayerEffect(.builtIn(effect))
    }

    public var debugName: String {
        switch implementation {
        case .compiled(let effect): effect.name
        case .builtIn(let effect): effect.debugName
        }
    }

    public var isCompiled: Bool {
        if case .compiled = implementation { return true }
        return false
    }

    /// Whether this runs, given the user's current settings.
    public func isActive(with properties: [String: DynamicValue]) -> Bool {
        visibility?.isVisible(with: properties) ?? true
    }
}

public extension Array where Element == LayerEffect {
    /// The approximated steps only, for paths that cannot run compiled chains.
    var builtInOnly: [PostEffect] {
        compactMap { step in
            if case .builtIn(let effect) = step.implementation { return effect }
            return nil
        }
    }

    /// The steps that run given the user's current settings.
    ///
    /// Returns the array untouched when nothing in it is bound to a property, which is almost
    /// always, so the common frame allocates nothing here.
    func active(with properties: [String: DynamicValue]) -> [LayerEffect] {
        guard contains(where: { $0.visibility != nil }) else { return self }
        return filter { $0.isActive(with: properties) }
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

    /// How many times a pass was given a fresh target because it read the one it writes.
    ///
    /// Observable because the alternative is untestable: on a tile-based GPU, sampling a texture
    /// you are also rendering into happens to return its pre-clear contents from device memory,
    /// so the broken version produces the right pixels on this hardware and the wrong ones
    /// elsewhere. A pixel test cannot tell the two apart; this can.
    public private(set) var hazardsAvoided = 0

    public init(materials: MaterialRenderer) {
        self.materials = materials
    }

    /// A full-screen quad in clip space.
    ///
    /// The unit quad the material path draws spans -0.5 to 0.5, so doubling it covers the
    /// target exactly. Effect shaders read their position through the same
    /// `g_ModelViewProjection` a layer's shader does, so there is nothing special to bind.
    public static let fullscreenTransform = simd_float4x4(diagonal: SIMD4(2, 2, 1, 1))

    /// The `N` in a sampler named `g_TextureN`, which is what a `bind` index refers to.
    static func textureIndex(of samplerName: String) -> Int? {
        guard samplerName.hasPrefix("g_Texture") else { return nil }
        return Int(samplerName.dropFirst("g_Texture".count))
    }

    /// Runs `effect`, reading `source` and leaving the result in `destination`.
    ///
    /// Returns false when the chain could not run, so the caller can fall back rather than
    /// leaving the destination undefined.
    /// `DIORAMA_EFFECT_TRACE`, read once. `ProcessInfo.environment` copies the whole
    /// environment into a new dictionary on every call, and this was asking once per pass per
    /// frame — in an effect-heavy scene, the largest single cost on the render path.
    private static let traceEnabled = ProcessInfo.processInfo.environment["DIORAMA_EFFECT_TRACE"] != nil

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

            // Inputs are resolved against the targets *as they stand before this pass runs*,
            // which is what lets the output allocation below notice that a pass reads the same
            // target it writes.
            var textures: [String: any MTLTexture] = [:]
            var sizes: [String: SIMD4<Float>] = [:]
            var repeating: Set<String> = []
            for (position, name) in pass.program.declaredSamplers.enumerated() {
                // A sampler not called `g_TextureN` has no index to be bound by; its position
                // is the only thing left to go on.
                let slot = Self.textureIndex(of: name) ?? position
                switch pass.inputs[slot] {
                case .texture(let loaded):
                    textures[name] = loaded.texture
                    sizes[name] = loaded.resolution
                    if loaded.repeats { repeating.insert(name) }
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

            if Self.traceEnabled {
                let bound = pass.program.declaredSamplers.enumerated().map { slot, name in
                    let texture = textures[name]
                    let what: String
                    if texture == nil { what = "UNBOUND" }
                    else if texture === source { what = "source" }
                    else { what = "\(texture!.width)x\(texture!.height)" }
                    return "[\(slot)]\(name)=\(what)"
                }.joined(separator: " ")
                let slots = pass.program.textureSlots
                    .sorted { $0.value < $1.value }
                    .map { "\($0.key)->\($0.value)" }.joined(separator: " ")
                FileHandle.standardError.write(Data(
                    "effect \(effect.name) pass \(index): \(bound) | reflected: \(slots)\n".utf8
                ))
            }

            // A pass naming no target writes the chain's output; so does the final pass, whose
            // target — if it names one — nothing downstream will read.
            let output: any MTLTexture
            var replacing: PooledTexture?
            if isLast {
                output = destination
            } else if let name = pass.target {
                let existing = targets[name]
                // Reusing the texture a pass is also reading would make it a render target and
                // a shader resource at once, which Metal leaves undefined — the pass would
                // sample whatever the GPU happened to have written so far. Ping-ponging onto a
                // fresh texture is what a framebuffer-based engine does anyway.
                let reads = existing.map { pooled in
                    textures.values.contains { $0 === pooled.texture }
                } ?? false

                let reusable = reads ? nil : existing
                let scale = max(1, effect.targetScales[name] ?? 1)
                guard let pooled = reusable ?? pool.acquire(
                    width: max(1, destination.width / scale),
                    height: max(1, destination.height / scale),
                    pixelFormat: destination.pixelFormat
                ) else {
                    log.error("no target available for \(effect.name, privacy: .public)")
                    return false
                }
                // Counted on the outcome, not on the detection: a counter bumped where the
                // hazard is *noticed* would keep reporting success if the swap below were
                // removed, which is how an earlier version of this passed with the fix reverted.
                if let existing, pooled !== existing {
                    replacing = existing
                    hazardsAvoided += 1
                }
                targets[name] = pooled
                output = pooled.texture
            } else {
                output = destination
            }
            // Released only after the pass is encoded, so the texture it reads stays alive.
            defer { if let replacing { pool.release(replacing) } }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = output
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: 0, green: 0, blue: 0, alpha: 0
            )
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return false }

            var passEngine = engine
            passEngine.screenSize = SIMD2(Float(output.width), Float(output.height))

            materials.encode(
                pass.program,
                context: MaterialRenderer.DrawContext(
                    transform: Self.fullscreenTransform,
                    projection: matrix_identity_float4x4,
                    textures: textures,
                    constants: pass.constants,
                    textureSizes: sizes,
                    repeatingTextures: repeating,
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
    /// - Parameter instance: this placement's own settings from `scene.json` — tuned values,
    ///   chosen variants and painted masks — layered over the effect file's, pass for pass.
    public func effect(
        for document: EffectDocument,
        instance: SceneEffect? = nil,
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

            // Three layers, most general first: the material, the effect file's pass, and this
            // placement's own settings for that pass.
            let placement = index < (instance?.passes.count ?? 0) ? instance?.passes[index] : nil
            var merged = materialPass
            merged.combos.merge(pass.combos) { _, effectValue in effectValue }
            if let placement {
                merged.combos.merge(placement.combos) { _, placed in placed }
                for (slot, path) in placement.textures.enumerated() {
                    guard let path, !path.isEmpty else { continue }
                    while merged.textures.count <= slot { merged.textures.append(nil) }
                    merged.textures[slot] = path
                }
            }

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
            // Textures named by the material or the placement — masks, noise, gradients. Slot 0
            // is left alone: in an effect it is the picture being processed, whatever a
            // material lists there. `bind` entries follow and win, because they are the
            // effect's own plumbing.
            for (slot, path) in merged.textures.enumerated() where slot > 0 {
                guard let path, !path.isEmpty else { continue }
                if let loaded = assets.sceneTexture(at: path, device: device) {
                    inputs[slot] = .texture(loaded)
                } else {
                    report.add(
                        .degraded, feature: "Effect",
                        detail: "\(name): texture \(path) is missing"
                    )
                }
            }
            // What is still unassigned reads its annotation's default, as in Wallpaper Engine.
            // Slot 0 excepted: it is always the picture being processed.
            for name in program.declaredSamplers {
                guard let slot = EffectChainRunner.textureIndex(of: name), slot > 0,
                      inputs[slot] == nil,
                      !pass.bindings.contains(where: { $0.index == slot }),
                      let reference = program.samplerDefaults[name],
                      let loaded = assets.sceneTexture(at: reference, device: device)
                else { continue }
                inputs[slot] = .texture(loaded)
            }
            for binding in pass.bindings {
                if binding.isChainInput {
                    inputs[binding.index] = .chainInput
                } else if binding.isRenderTarget {
                    inputs[binding.index] = .renderTarget(binding.name)
                } else if let loaded = assets.sceneTexture(at: binding.name, device: device) {
                    inputs[binding.index] = .texture(loaded)
                } else {
                    report.add(
                        .degraded, feature: "Effect",
                        detail: "\(name): texture \(binding.name) is missing"
                    )
                }
            }

            var constants = materialPass.constantShaderValues
            constants.merge(pass.constantShaderValues) { _, effectValue in effectValue }
            if let placement {
                constants.merge(placement.constantShaderValues) { _, placed in placed }
            }

            compiled.append(CompiledEffectPass(
                program: program, target: pass.target, inputs: inputs, constants: constants
            ))
        }

        return CompiledEffect(
            name: name,
            passes: compiled,
            targetScales: Dictionary(
                document.framebuffers.map { ($0.name, $0.scale) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }
}
