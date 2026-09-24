import Foundation
import Metal
import MetalRenderer
import ShaderTranspiler
import WEFormat
import simd
import os

/// Draws a layer through the material's own compiled shader.
///
/// The counterpart to `QuadRenderer`, which draws everything through one built-in shader. Both
/// produce the same unit quad; the difference is whose fragment shader runs.
///
/// Threading: render-queue only, like everything else in this module.
public final class MaterialRenderer {
    private let device: any MTLDevice
    private let samplerClamp: any MTLSamplerState
    private let samplerRepeat: any MTLSamplerState
    private let fallbackTexture: any MTLTexture
    private let log = Logger(subsystem: "app.diorama", category: "material")

    /// Constant buffers above Metal's `setBytes` threshold, kept per program so a shader with
    /// large uniform arrays does not allocate one per frame.
    private var scratchBuffers: [String: any MTLBuffer] = [:]

    /// Reused across draws so filling a constant buffer allocates nothing per frame.
    private var vertexScratch: [UInt8] = []
    private var fragmentScratch: [UInt8] = []
    /// Reused for the same reason the byte buffers are: an engine value read into a fresh
    /// array would be one allocation per uniform per draw per frame.
    private var floatScratch: [Float] = []
    private var unsuppliedScratch: [String] = []

    /// Counts draws that had to fall back to a placeholder texture, for the compatibility report.
    public private(set) var missingTextureBindings = 0

    public init(device: any MTLDevice) throws {
        self.device = device

        let clamp = MTLSamplerDescriptor()
        clamp.minFilter = .linear
        clamp.magFilter = .linear
        clamp.mipFilter = .linear
        clamp.sAddressMode = .clampToEdge
        clamp.tAddressMode = .clampToEdge
        guard let clampState = device.makeSamplerState(descriptor: clamp) else {
            throw RendererError.samplerCreationFailed
        }
        samplerClamp = clampState

        let repeating = MTLSamplerDescriptor()
        repeating.minFilter = .linear
        repeating.magFilter = .linear
        repeating.mipFilter = .linear
        repeating.sAddressMode = .repeat
        repeating.tAddressMode = .repeat
        guard let repeatState = device.makeSamplerState(descriptor: repeating) else {
            throw RendererError.samplerCreationFailed
        }
        samplerRepeat = repeatState

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let fallback = device.makeTexture(descriptor: descriptor) else {
            throw RendererError.textureCreationFailed
        }
        var white: UInt32 = 0xFFFF_FFFF
        fallback.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4
        )
        fallback.label = "material-fallback-white"
        fallbackTexture = fallback
    }

    /// Everything the shader needs that is not baked into the program.
    public struct DrawContext {
        public var transform: simd_float4x4
        public var projection: simd_float4x4
        /// Sampler name to the texture it should read, e.g. `g_Texture0`.
        public var textures: [String: any MTLTexture]
        public var constants: [String: DynamicValue]
        /// `g_TextureNResolution` per sampler: allocation in `xy`, image in `zw`. Empty means
        /// "ask the textures themselves", which is right for anything not padded.
        public var textureSizes: [String: SIMD4<Float>]
        /// Samplers whose texture was authored to tile, and so wraps rather than clamps.
        public var repeatingTextures: Set<String>
        /// The user's own settings for this wallpaper, keyed as `project.json` keys them.
        public var overrides: [String: DynamicValue]
        public var engine: EngineUniforms
        public var wrapsUVs: Bool

        public init(
            transform: simd_float4x4,
            projection: simd_float4x4,
            textures: [String: any MTLTexture] = [:],
            constants: [String: DynamicValue] = [:],
            textureSizes: [String: SIMD4<Float>] = [:],
            repeatingTextures: Set<String> = [],
            overrides: [String: DynamicValue] = [:],
            engine: EngineUniforms = EngineUniforms(),
            wrapsUVs: Bool = false
        ) {
            self.transform = transform
            self.projection = projection
            self.textures = textures
            self.constants = constants
            self.textureSizes = textureSizes
            self.repeatingTextures = repeatingTextures
            self.overrides = overrides
            self.engine = engine
            self.wrapsUVs = wrapsUVs
        }
    }

    /// What filling the buffers found, so the caller can report it once rather than per frame.
    @discardableResult
    public func encode(
        _ program: MaterialProgram,
        context: DrawContext,
        into encoder: any MTLRenderCommandEncoder
    ) -> [String] {
        encoder.setRenderPipelineState(program.pipeline)
        encoder.setVertexBuffer(program.vertexBuffer, offset: 0, index: program.vertexBufferIndex)

        // The shader's own `g_ModelViewProjection` is the only place the layer's placement
        // reaches it: unlike the built-in quad path there is no separate transform uniform.
        var engine = context.engine
        engine.modelViewProjection = context.projection * context.transform
        // `g_TextureNResolution` is how a Wallpaper Engine shader learns the size of what it
        // samples, and stock effects divide by it: `foliagesway.vert` computes an aspect ratio
        // as `g_Texture0Resolution.z / .w` and feeds it into every UV the fragment stage then
        // samples with. Nothing ever filled this array, so that division was 0/0, and a single
        // NaN UV turns the whole pass white. That is what "scenes are just a static image"
        // actually was — the composition underneath was correct the whole time.
        engine.textureResolutions = Self.textureResolutions(
            declared: program.declaredSamplers,
            textures: context.textures,
            sizes: context.textureSizes
        )

        unsuppliedScratch.removeAll(keepingCapacity: true)

        if let slot = program.vertexBufferSlot, !program.vertexLayout.isEmpty {
            UniformBufferWriter.fill(
                into: &vertexScratch,
                plan: program.uniformPlans.vertex,
                constants: context.constants,
                overrides: context.overrides,
                engine: engine,
                scratch: &floatScratch,
                unsupplied: &unsuppliedScratch
            )
            bind(
                vertexScratch, count: program.vertexLayout.size,
                key: program.uniformPlans.vertexKey, slot: slot, encoder: encoder, stage: .vertex
            )
        }

        if let slot = program.fragmentBufferSlot, !program.fragmentLayout.isEmpty {
            UniformBufferWriter.fill(
                into: &fragmentScratch,
                plan: program.uniformPlans.fragment,
                constants: context.constants,
                overrides: context.overrides,
                engine: engine,
                scratch: &floatScratch,
                unsupplied: &unsuppliedScratch
            )
            bind(
                fragmentScratch, count: program.fragmentLayout.size,
                key: program.uniformPlans.fragmentKey, slot: slot, encoder: encoder,
                stage: .fragment
            )
        }
        let unsupplied = unsuppliedScratch

        // Bound by name through the slots the translator reported. Binding by declaration order
        // would swap textures on any shader whose combos leave a sampler unused, because
        // SPIRV-Cross drops those and renumbers the rest.
        for (name, slot) in program.textureSlots.sorted(by: { $0.value < $1.value }) {
            // Per texture: masks clamp and tiling textures wrap, both in one pass.
            let sampler = context.wrapsUVs || context.repeatingTextures.contains(name)
                ? samplerRepeat : samplerClamp
            if let texture = context.textures[name] {
                encoder.setFragmentTexture(texture, index: slot)
            } else {
                encoder.setFragmentTexture(fallbackTexture, index: slot)
                missingTextureBindings += 1
            }
            if let samplerSlot = program.samplerSlots[name] {
                encoder.setFragmentSamplerState(sampler, index: samplerSlot)
            }
        }

        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: program.vertexCount
        )
        return unsupplied
    }

    public func resetCounters() { missingTextureBindings = 0 }

    /// Resolutions indexed by the `N` in `g_TextureN`, which is how `g_TextureNResolution`
    /// is looked up.
    ///
    /// A slot with no texture reports 1x1 rather than 0x0. Both are untrue, but a shader that
    /// divides by a missing texture's size gets finite nonsense from one and a NaN from the
    /// other — and a NaN spreads to every pixel the UV touches, so one absent stock asset
    /// would blank the whole wallpaper instead of dropping one detail.
    /// - Parameter sizes: measured resolutions for samplers whose texture is padded, where the
    ///   allocation alone would overstate the image. Anything absent falls back to the
    ///   allocation, which is right for render targets and for unpadded textures alike.
    static func textureResolutions(
        declared: [String],
        textures: [String: any MTLTexture],
        sizes: [String: SIMD4<Float>] = [:]
    ) -> [SIMD4<Float>] {
        var resolutions: [SIMD4<Float>] = []
        for name in Set(declared).union(textures.keys).union(sizes.keys).sorted() {
            guard name.hasPrefix("g_Texture"),
                  let slot = Int(name.dropFirst("g_Texture".count)), slot >= 0
            else { continue }
            if resolutions.count <= slot {
                resolutions.append(contentsOf: repeatElement(
                    SIMD4(1, 1, 1, 1), count: slot + 1 - resolutions.count
                ))
            }
            if let measured = sizes[name] {
                resolutions[slot] = measured
            } else if let texture = textures[name] {
                let width = Float(texture.width), height = Float(texture.height)
                resolutions[slot] = SIMD4(width, height, width, height)
            }
        }
        return resolutions
    }

    // MARK: - Buffers

    /// Metal's `setBytes` fast path stops at 4KB; above that the data has to live in a buffer.
    static let inlineByteLimit = 4096

    private enum Stage { case vertex, fragment }

    /// - Parameter count: bytes to bind. The scratch array may be larger than this layout,
    ///   since it is sized to the largest one seen so far and never shrinks.
    private func bind(
        _ bytes: [UInt8],
        count: Int,
        key: String,
        slot: Int,
        encoder: any MTLRenderCommandEncoder,
        stage: Stage
    ) {
        guard count > 0, bytes.count >= count else { return }

        if count <= Self.inlineByteLimit {
            bytes.withUnsafeBytes { raw in
                switch stage {
                case .vertex:
                    encoder.setVertexBytes(raw.baseAddress!, length: count, index: slot)
                case .fragment:
                    encoder.setFragmentBytes(raw.baseAddress!, length: count, index: slot)
                }
            }
            return
        }

        // Reused across frames: a shader with large uniform arrays would otherwise allocate
        // once per draw, which is exactly the per-frame allocation PLAN.md §6 rules out.
        let buffer: any MTLBuffer
        if let existing = scratchBuffers[key], existing.length >= count {
            buffer = existing
        } else {
            guard let made = device.makeBuffer(length: count, options: .storageModeShared) else {
                log.error("could not allocate a constant buffer for \(key, privacy: .public)")
                return
            }
            made.label = "uniforms-\(key)"
            scratchBuffers[key] = made
            buffer = made
        }

        bytes.withUnsafeBytes { raw in
            buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: count)
        }
        switch stage {
        case .vertex: encoder.setVertexBuffer(buffer, offset: 0, index: slot)
        case .fragment: encoder.setFragmentBuffer(buffer, offset: 0, index: slot)
        }
    }
}
