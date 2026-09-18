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
        public var engine: EngineUniforms
        public var wrapsUVs: Bool

        public init(
            transform: simd_float4x4,
            projection: simd_float4x4,
            textures: [String: any MTLTexture] = [:],
            constants: [String: DynamicValue] = [:],
            engine: EngineUniforms = EngineUniforms(),
            wrapsUVs: Bool = false
        ) {
            self.transform = transform
            self.projection = projection
            self.textures = textures
            self.constants = constants
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

        var unsupplied: [String] = []

        if let slot = program.vertexBufferSlot, !program.vertexLayout.isEmpty {
            unsupplied += UniformBufferWriter.fill(
                into: &vertexScratch,
                layout: program.vertexLayout,
                declarations: program.vertexUniforms,
                constants: context.constants,
                engine: engine
            )
            bind(
                vertexScratch, count: program.vertexLayout.size,
                key: program.name + ".vert", slot: slot, encoder: encoder, stage: .vertex
            )
        }

        if let slot = program.fragmentBufferSlot, !program.fragmentLayout.isEmpty {
            unsupplied += UniformBufferWriter.fill(
                into: &fragmentScratch,
                layout: program.fragmentLayout,
                declarations: program.fragmentUniforms,
                constants: context.constants,
                engine: engine
            )
            bind(
                fragmentScratch, count: program.fragmentLayout.size,
                key: program.name + ".frag", slot: slot, encoder: encoder, stage: .fragment
            )
        }

        // Bound by name through the slots the translator reported. Binding by declaration order
        // would swap textures on any shader whose combos leave a sampler unused, because
        // SPIRV-Cross drops those and renumbers the rest.
        let sampler = context.wrapsUVs ? samplerRepeat : samplerClamp
        for (name, slot) in program.textureSlots.sorted(by: { $0.value < $1.value }) {
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
