import Foundation

/// One rendering pass of a material.
///
/// Wallpaper Engine materials are a list of passes; the common case for an image layer is
/// exactly one, naming a shader and the textures it samples.
public struct MaterialPass: Sendable, Hashable, Codable {
    /// Blend mode name as written in the material, e.g. `"normal"`, `"additive"`.
    public var blending: String?
    public var cullMode: String?
    public var depthTest: String?
    public var depthWrite: String?
    /// Shader base name, without extension — the `.vert`/`.frag` pair share it.
    public var shader: String?
    /// Texture paths relative to the package root. Entries may be null: a pass can declare a
    /// slot it does not bind, and the index position is significant, so nulls must be preserved
    /// rather than compacted away.
    public var textures: [String?]
    /// Combo variant selections for the shader.
    public var combos: [String: Int]
    /// Literal uniform values baked into the material.
    public var constantShaderValues: [String: DynamicValue]

    public init(
        blending: String? = nil, cullMode: String? = nil, depthTest: String? = nil,
        depthWrite: String? = nil, shader: String? = nil, textures: [String?] = [],
        combos: [String: Int] = [:], constantShaderValues: [String: DynamicValue] = [:]
    ) {
        self.blending = blending
        self.cullMode = cullMode
        self.depthTest = depthTest
        self.depthWrite = depthWrite
        self.shader = shader
        self.textures = textures
        self.combos = combos
        self.constantShaderValues = constantShaderValues
    }

    private enum CodingKeys: String, CodingKey {
        case blending, cullmode, depthtest, depthwrite, shader, textures, combos
        case constantshadervalues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blending = try container.decodeIfPresent(String.self, forKey: .blending)
        cullMode = try container.decodeIfPresent(String.self, forKey: .cullmode)
        depthTest = try container.decodeIfPresent(String.self, forKey: .depthtest)
        depthWrite = try container.decodeIfPresent(String.self, forKey: .depthwrite)
        shader = try container.decodeIfPresent(String.self, forKey: .shader)
        textures = try container.decodeIfPresent([String?].self, forKey: .textures) ?? []
        combos = try container.decodeIfPresent([String: Int].self, forKey: .combos) ?? [:]
        constantShaderValues = try container.decodeIfPresent(
            [String: DynamicValue].self, forKey: .constantshadervalues
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(blending, forKey: .blending)
        try container.encodeIfPresent(cullMode, forKey: .cullmode)
        try container.encodeIfPresent(depthTest, forKey: .depthtest)
        try container.encodeIfPresent(depthWrite, forKey: .depthwrite)
        try container.encodeIfPresent(shader, forKey: .shader)
        try container.encode(textures, forKey: .textures)
        try container.encode(combos, forKey: .combos)
        try container.encode(constantShaderValues, forKey: .constantshadervalues)
    }

    /// The first bound texture, which is the colour map for an ordinary image layer.
    public var primaryTexture: String? {
        textures.compactMap { $0 }.first { !$0.isEmpty }
    }
}

public struct MaterialDocument: Sendable, Hashable, Codable {
    public var passes: [MaterialPass]

    public init(passes: [MaterialPass] = []) {
        self.passes = passes
    }

    private enum CodingKeys: String, CodingKey { case passes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        passes = try container.decodeIfPresent([MaterialPass].self, forKey: .passes) ?? []
    }

    public var firstPass: MaterialPass? { passes.first }
}
