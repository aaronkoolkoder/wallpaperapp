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

    public init(
        name: String? = nil, group: String? = nil, description: String? = nil,
        passes: [EffectPass] = [], passesDependencies: [String] = []
    ) {
        self.name = name
        self.group = group
        self.description = description
        self.passes = passes
        self.passesDependencies = passesDependencies
    }

    private enum CodingKeys: String, CodingKey {
        case name, group, description, passes, dependencies
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
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(passes, forKey: .passes)
        try container.encode(passesDependencies, forKey: .dependencies)
    }

    /// Best-effort classification of what this effect actually does.
    ///
    /// Running an arbitrary Wallpaper Engine effect needs its shaders transpiled to MSL, which
    /// is not wired up yet. Until it is, effects are matched by name against built-in
    /// implementations — which covers the handful that appear in most wallpapers — and anything
    /// unmatched is reported rather than silently skipped.
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
