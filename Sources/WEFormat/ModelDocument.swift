import Foundation

/// The indirection between a scene object and the material that draws it.
///
/// A scene object's `image` field names one of these, not a material: `"image":
/// "models/foo.json"` pointing at `{"material": "materials/foo.json", "autosize": true}`.
/// Reading that file as a material finds no passes and drops the layer, which is what happened
/// to every scene in the first real Workshop library this was pointed at — all 59 of them
/// reported "declares no passes" and rendered one layer between them.
public struct ModelDocument: Sendable, Hashable, Codable {
    /// Path of the material that actually describes the shader and textures.
    public var material: String?

    /// Take the layer's size from the texture rather than the object's declared size.
    public var autosize: Bool?

    /// A `.mdl` skeleton for puppet-warp animation.
    ///
    /// Recorded so the compatibility report can name what a wallpaper wanted; nothing reads it
    /// yet, and a layer with one still draws — it just will not deform.
    public var puppet: String?

    public init(material: String? = nil, autosize: Bool? = nil, puppet: String? = nil) {
        self.material = material
        self.autosize = autosize
        self.puppet = puppet
    }

    public init(from decoder: Decoder) throws {
        let object = try CaseInsensitiveContainer(from: decoder)
        material = object.string("material")
        autosize = object.value(Bool.self, "autosize")
        puppet = object.string("puppet")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeIfPresent(material, "material")
        try container.encodeIfPresent(autosize, "autosize")
        try container.encodeIfPresent(puppet, "puppet")
    }
}
