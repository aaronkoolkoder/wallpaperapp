//
//  BlendMode.swift
//  MetalRenderer
//

import Metal

/// The 2D compositing blend modes the renderer supports, and their mapping onto
/// Metal's fixed-function blend unit.
///
/// ## Threading contract
///
/// Plain `Sendable` value type. Usable from any isolation domain.
///
/// ## The straight vs. premultiplied rule
///
/// Every mode here follows one rule, so there is exactly one thing to remember:
///
/// - **Straight (non-premultiplied)** source colour still needs to be weighted by its
///   own alpha, so the source factor carries `.sourceAlpha`.
/// - **Premultiplied** source colour already has alpha baked in, so the source factor
///   is `.one`.
///
/// The destination factor is what distinguishes one mode from another:
///
/// | mode       | dst factor            | resulting colour (opaque source)   |
/// |------------|-----------------------|------------------------------------|
/// | alpha      | `.oneMinusSourceAlpha`| `src`                              |
/// | additive   | `.one`                | `src + dst`                        |
/// | screen     | `.oneMinusSourceColor`| `src + dst·(1-src)` = `1-(1-s)(1-d)`|
/// | multiply   | `.zero` / `1-srcA`    | `src · dst`                        |
///
/// Alpha-channel blending is handled separately from colour in every mode so that the
/// destination's coverage accumulates correctly rather than being clobbered.
///
/// ## Overlay is not a fixed-function mode
///
/// `overlay` is a per-channel conditional (`dst < 0.5 ? 2·s·d : 1-2(1-s)(1-d)`). No
/// combination of Metal blend factors expresses it. See ``requiresProgrammableBlending``.
public enum BlendMode: UInt8, Sendable, Hashable, CaseIterable, CustomStringConvertible {

    /// Source replaces destination; the blend unit is switched off entirely.
    ///
    /// This is the cheapest mode and the correct one for an opaque background layer.
    /// Disabling blending also lets the GPU skip the destination read, which on a tiled
    /// Apple GPU is a real bandwidth saving on a full-screen quad.
    case normal

    /// Straight-alpha source-over. The default for a layer with a transparency mask.
    case alphaBlend

    /// Source-over with colour already multiplied by alpha. Preferred over
    /// ``alphaBlend`` when the content pipeline can produce it: premultiplied compositing
    /// is correct under filtering and mipmapping, straight alpha is not.
    case premultipliedAlpha

    /// Additive / linear-dodge. Used by glow, sparks, and most particle systems.
    case additive

    case premultipliedAdditive

    /// `src · dst`. Darkens. Assumes an opaque source; use
    /// ``premultipliedMultiply`` if the source has partial coverage.
    case multiply

    case premultipliedMultiply

    /// `1 - (1-src)·(1-dst)`. Lightens; the complement of multiply.
    case screen

    case premultipliedScreen

    /// Per-channel hard-light against the destination. **Not** expressible with the
    /// fixed-function blend unit — see ``requiresProgrammableBlending``.
    case overlay

    // MARK: - Classification

    /// True when the mode can be realised by the GPU's blend unit alone.
    ///
    /// When false the caller must instead use a fragment shader that reads the
    /// destination. On Apple Silicon that read is free: declare the previous colour as a
    /// `[[color(0)]]` fragment input and the value comes out of tile memory without ever
    /// touching device memory. That is why this renderer models overlay as a shader
    /// concern rather than refusing to support it — but it does mean an overlay layer
    /// needs its own pipeline variant, so the distinction has to be visible in the
    /// pipeline cache key.
    public var requiresProgrammableBlending: Bool { self == .overlay }

    /// True when the source colour is expected to arrive with alpha already applied.
    public var isPremultiplied: Bool {
        switch self {
        case .premultipliedAlpha, .premultipliedAdditive,
             .premultipliedMultiply, .premultipliedScreen:
            return true
        case .normal, .alphaBlend, .additive, .multiply, .screen, .overlay:
            return false
        }
    }

    /// True when the blend unit is enabled at all.
    ///
    /// `normal` and `overlay` both report `false`, for opposite reasons: `normal` needs
    /// no blending, `overlay` cannot use it.
    public var isBlendingEnabled: Bool {
        switch self {
        case .normal, .overlay: return false
        default: return true
        }
    }

    public var description: String {
        switch self {
        case .normal: return "normal"
        case .alphaBlend: return "alphaBlend"
        case .premultipliedAlpha: return "premultipliedAlpha"
        case .additive: return "additive"
        case .premultipliedAdditive: return "premultipliedAdditive"
        case .multiply: return "multiply"
        case .premultipliedMultiply: return "premultipliedMultiply"
        case .screen: return "screen"
        case .premultipliedScreen: return "premultipliedScreen"
        case .overlay: return "overlay"
        }
    }

    // MARK: - Factors

    /// The four blend factors plus the two operations, as a value type.
    ///
    /// Broken out from ``apply(to:)`` so the mapping can be unit-tested without
    /// constructing a Metal descriptor — which matters because the test machine in CI
    /// may not have a GPU.
    public struct Factors: Sendable, Hashable {
        public var sourceRGB: MTLBlendFactor
        public var destinationRGB: MTLBlendFactor
        public var rgbOperation: MTLBlendOperation
        public var sourceAlpha: MTLBlendFactor
        public var destinationAlpha: MTLBlendFactor
        public var alphaOperation: MTLBlendOperation

        public init(
            sourceRGB: MTLBlendFactor,
            destinationRGB: MTLBlendFactor,
            rgbOperation: MTLBlendOperation = .add,
            sourceAlpha: MTLBlendFactor,
            destinationAlpha: MTLBlendFactor,
            alphaOperation: MTLBlendOperation = .add
        ) {
            self.sourceRGB = sourceRGB
            self.destinationRGB = destinationRGB
            self.rgbOperation = rgbOperation
            self.sourceAlpha = sourceAlpha
            self.destinationAlpha = destinationAlpha
            self.alphaOperation = alphaOperation
        }
    }

    /// The blend factors for this mode, or `nil` when blending is disabled.
    public var factors: Factors? {
        switch self {
        case .normal, .overlay:
            return nil

        case .alphaBlend:
            // Colour is weighted by source alpha; the alpha channel uses `.one` on the
            // source so coverage composites as 1-(1-a_s)(1-a_d) rather than being
            // squared, which is what you get if you naively reuse the colour factors.
            return Factors(
                sourceRGB: .sourceAlpha, destinationRGB: .oneMinusSourceAlpha,
                sourceAlpha: .one, destinationAlpha: .oneMinusSourceAlpha
            )

        case .premultipliedAlpha:
            return Factors(
                sourceRGB: .one, destinationRGB: .oneMinusSourceAlpha,
                sourceAlpha: .one, destinationAlpha: .oneMinusSourceAlpha
            )

        case .additive:
            // Destination alpha is preserved: an additive glow brightens what is behind
            // it without claiming coverage of its own.
            return Factors(
                sourceRGB: .sourceAlpha, destinationRGB: .one,
                sourceAlpha: .zero, destinationAlpha: .one
            )

        case .premultipliedAdditive:
            return Factors(
                sourceRGB: .one, destinationRGB: .one,
                sourceAlpha: .one, destinationAlpha: .one
            )

        case .multiply:
            // src·dst exactly. Note there is no `.oneMinusSourceAlpha` term here: with a
            // straight-alpha source, a partially transparent pixel cannot be expressed by
            // the blend unit without over-darkening, so this mode is defined for opaque
            // sources and `premultipliedMultiply` handles the general case.
            return Factors(
                sourceRGB: .destinationColor, destinationRGB: .zero,
                sourceAlpha: .zero, destinationAlpha: .one
            )

        case .premultipliedMultiply:
            // dst·src + dst·(1-a) — collapses to dst·src at a=1 and to dst at a=0,
            // which is the coverage-correct generalisation of multiply.
            return Factors(
                sourceRGB: .destinationColor, destinationRGB: .oneMinusSourceAlpha,
                sourceAlpha: .zero, destinationAlpha: .one
            )

        case .screen:
            return Factors(
                sourceRGB: .sourceAlpha, destinationRGB: .oneMinusSourceColor,
                sourceAlpha: .one, destinationAlpha: .oneMinusSourceAlpha
            )

        case .premultipliedScreen:
            return Factors(
                sourceRGB: .one, destinationRGB: .oneMinusSourceColor,
                sourceAlpha: .one, destinationAlpha: .oneMinusSourceAlpha
            )
        }
    }

    /// Configure a colour attachment for this mode.
    ///
    /// Called once per unique pipeline at build time, never per frame — see
    /// ``PipelineCache``.
    public func apply(to attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        guard let factors else {
            attachment.isBlendingEnabled = false
            return
        }
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = factors.sourceRGB
        attachment.destinationRGBBlendFactor = factors.destinationRGB
        attachment.rgbBlendOperation = factors.rgbOperation
        attachment.sourceAlphaBlendFactor = factors.sourceAlpha
        attachment.destinationAlphaBlendFactor = factors.destinationAlpha
        attachment.alphaBlendOperation = factors.alphaOperation
    }
}
