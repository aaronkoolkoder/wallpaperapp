import Foundation

/// A texture bound into an effect pass.
public struct EffectBinding: Sendable, Hashable, Codable {
    /// Sampler slot the texture arrives in.
    public var index: Int
    /// Source name. Render-target names begin with `_rt_`; anything else is a file path.
    public var name: String

    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }

    /// Whether this names an intermediate render target rather than a texture on disk.
    public var isRenderTarget: Bool { name.hasPrefix("_rt_") }

    /// Whether this is the effect's own input: the layer as it stands before the effect runs,
    /// or the frame so far for a scene effect.
    ///
    /// Wallpaper Engine spells it `previous` rather than giving it an `_rt_` name, so it reads
    /// like a file. Looked up as one it is always missing, and the pass samples the renderer's
    /// white placeholder where the picture should be — blur's final pass blends the blurred
    /// image with that, which turned every blurred layer white.
    public var isChainInput: Bool { name == "previous" }
}

/// A render target an effect declares for its own passes, from its `fbos` block.
public struct EffectFramebuffer: Sendable, Hashable, Codable {
    public var name: String
    /// Divisor of the output size: 4 is a quarter-resolution target. Blur and bloom work at
    /// reduced resolution on purpose — it is what makes them cheap, and it sets how far they
    /// spread, so running them at full size is both slower and visibly weaker.
    public var scale: Int
    public var format: String?

    public init(name: String, scale: Int = 1, format: String? = nil) {
        self.name = name
        self.scale = max(1, scale)
        self.format = format
    }

    private enum CodingKeys: String, CodingKey { case name, scale, format }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        // Written as an integer in every effect seen so far; a fractional one is read rather
        // than rejected, and anything unreadable means full size.
        let whole = try? container.decodeIfPresent(Int.self, forKey: .scale)
        let fractional = try? container.decodeIfPresent(Double.self, forKey: .scale)
        scale = max(1, whole ?? fractional.map { Int($0.rounded()) } ?? 1)
        format = try container.decodeIfPresent(String.self, forKey: .format)
    }
}

/// One pass of an effect chain.
public struct EffectPass: Sendable, Hashable, Codable {
    /// Material supplying the shader for this pass.
    public var material: String?
    /// Render target written by this pass. Absent means it writes to the chain's output.
    public var target: String?
    public var bindings: [EffectBinding]
    /// Combo variant selections.
    public var combos: [String: Int]
    public var constantShaderValues: [String: DynamicValue]

    public init(
        material: String? = nil, target: String? = nil, bindings: [EffectBinding] = [],
        combos: [String: Int] = [:], constantShaderValues: [String: DynamicValue] = [:]
    ) {
        self.material = material
        self.target = target
        self.bindings = bindings
        self.combos = combos
        self.constantShaderValues = constantShaderValues
    }

    private enum CodingKeys: String, CodingKey {
        case material, target, bind, combos, constantshadervalues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        material = try container.decodeIfPresent(String.self, forKey: .material)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        bindings = try container.decodeIfPresent([EffectBinding].self, forKey: .bind) ?? []
        combos = try container.decodeIfPresent([String: Int].self, forKey: .combos) ?? [:]
        constantShaderValues = try container.decodeIfPresent(
            [String: DynamicValue].self, forKey: .constantshadervalues
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(material, forKey: .material)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encode(bindings, forKey: .bind)
        try container.encode(combos, forKey: .combos)
        try container.encode(constantShaderValues, forKey: .constantshadervalues)
    }
}

/// An effect definition, as found at `effects/<name>.json`.
public struct EffectDocument: Sendable, Hashable, Codable {
    public var name: String?
    public var group: String?
    public var description: String?
    public var passes: [EffectPass]
    /// Declared user-configurable properties for this effect.
    public var passesDependencies: [String]
    /// Intermediate targets the passes write, with their sizes.
    public var framebuffers: [EffectFramebuffer]

    public init(
        name: String? = nil, group: String? = nil, description: String? = nil,
        passes: [EffectPass] = [], passesDependencies: [String] = [],
        framebuffers: [EffectFramebuffer] = []
    ) {
        self.name = name
        self.group = group
        self.description = description
        self.passes = passes
        self.passesDependencies = passesDependencies
        self.framebuffers = framebuffers
    }

    private enum CodingKeys: String, CodingKey {
        case name, group, description, passes, dependencies, fbos
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        passes = try container.decodeIfPresent([EffectPass].self, forKey: .passes) ?? []
        passesDependencies = try container.decodeIfPresent(
            [String].self, forKey: .dependencies
        ) ?? []
        framebuffers = try container.decodeIfPresent(
            [EffectFramebuffer].self, forKey: .fbos
        ) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(passes, forKey: .passes)
        try container.encode(passesDependencies, forKey: .dependencies)
        try container.encode(framebuffers, forKey: .fbos)
    }

    /// Best-effort classification of what this effect actually does.
    ///
    /// This is the *fallback* path. An effect whose shaders compile runs its own passes; this
    /// is what happens when they do not — the shader toolchain is not vendored in this build,
    /// a pass names a material that is missing, or a shader will not compile. Matching by name
    /// covers the handful of effects that appear in most wallpapers, and anything unmatched is
    /// reported rather than silently skipped.
    public var classifiedKind: String {
        let haystack = [name, description, passes.first?.material]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        for candidate in ["bloom", "blur", "chromatic", "vignette", "sharpen", "pixelate"]
        where haystack.contains(candidate) {
            return candidate
        }
        return "unknown"
    }
}
