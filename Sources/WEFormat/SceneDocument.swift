import Foundation

/// An object's visibility, which is not always a boolean.
///
/// Wallpaper Engine lets a wallpaper bind visibility to a user property or to a script
/// expression, in which case the JSON holds a string instead of `true`/`false`. Collapsing
/// that to a bool at parse time would silently pin such objects on or off, so the string is
/// preserved for the scene runtime to evaluate.
public enum SceneVisibility: Sendable, Hashable, Codable {
    case constant(Bool)
    case expression(String)

    /// Value to use before any expression has been evaluated. Objects default to visible,
    /// matching the editor's own behaviour for an unbound expression.
    public var staticValue: Bool {
        switch self {
        case let .constant(value): return value
        case .expression: return true
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .constant(value)
        } else if let value = try? container.decode(Double.self) {
            self = .constant(value != 0)
        } else if let text = try? container.decode(String.self) {
            switch text.lowercased() {
            case "true", "1": self = .constant(true)
            case "false", "0": self = .constant(false)
            default: self = .expression(text)
            }
        } else {
            throw DecodingError.typeMismatch(
                SceneVisibility.self,
                .init(codingPath: container.codingPath, debugDescription: "expected a bool or an expression")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .constant(value): try container.encode(value)
        case let .expression(text): try container.encode(text)
        }
    }
}

/// What a scene object *is*.
///
/// `scene.json` has no `type` discriminator — the kind is implied by which payload key the
/// object carries (`image`, `sound`, `particle`, `text`), so that is how it is inferred
/// here. An object with none of them decodes as ``unknown`` and is reported rather than
/// dropped.
public enum SceneObjectKind: String, Sendable, Hashable, Codable {
    case image
    case sound
    case particle
    case text
    case unknown
}

/// A post-process effect attached to an object.
///
/// The passes themselves live in the referenced `effects/*.json` file; this is only the
/// reference and the per-instance state that `scene.json` carries.
public struct SceneEffect: Sendable, Hashable, Codable {
    public var id: Int?
    public var name: String?
    /// Path of the effect definition inside the package, e.g. `"effects/water.json"`.
    public var file: String?
    public var visible: SceneVisibility?

    public init(id: Int? = nil, name: String? = nil, file: String? = nil, visible: SceneVisibility? = nil) {
        self.id = id
        self.name = name
        self.file = file
        self.visible = visible
    }

    public init(from decoder: Decoder) throws {
        let object = try CaseInsensitiveContainer(from: decoder)
        id = object.int("id")
        name = object.string("name")
        file = object.string("file")
        visible = object.value(SceneVisibility.self, "visible")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeIfPresent(id, "id")
        try container.encodeIfPresent(name, "name")
        try container.encodeIfPresent(file, "file")
        try container.encodeIfPresent(visible, "visible")
    }
}

/// One entry of `scene.json`'s `objects` array.
///
/// Every field is optional: the editor omits defaults, and objects of different kinds share
/// the same flat record. ``kind`` is derived, not read.
public struct SceneObject: Sendable, Hashable, Codable {

    public var id: Int?
    public var name: String?

    /// World-space position. Stored as `"x y z"`.
    public var origin: WEVector3?
    /// Euler rotation in degrees, `"pitch yaw roll"`.
    public var angles: WEVector3?
    public var scale: WEVector3?
    /// Quad dimensions in world units, for image and text objects.
    public var size: WEVector2?

    public var visible: SceneVisibility?

    /// Per-axis parallax response to camera or mouse movement.
    public var parallaxDepth: WEVector2?

    public var color: WEVector3?
    public var alpha: Double?

    /// Derived from which payload key is present. See ``SceneObjectKind``.
    public var kind: SceneObjectKind

    /// Model reference for an image object, e.g. `"models/background.json"`. The model in
    /// turn names the material.
    public var image: String?
    /// Particle system reference, e.g. `"particles/smoke.json"`.
    public var particle: String?
    /// Literal string for a text object.
    public var text: String?
    /// Audio file references. Sound objects store an array; a bare string is accepted too.
    public var sounds: [String]

    /// Direct material reference, when the object overrides the model's own material.
    public var material: String?

    /// Ordered effect chain applied to this object's rendered output.
    public var effects: [SceneEffect]
    /// SceneScript bodies keyed by the property they animate: `alpha`, `origin`, `angles`,
    /// `scale`, `color`. Empty for the overwhelming majority of objects.
    public var scripts: [String: String]

    public init(
        id: Int? = nil,
        name: String? = nil,
        origin: WEVector3? = nil,
        angles: WEVector3? = nil,
        scale: WEVector3? = nil,
        size: WEVector2? = nil,
        visible: SceneVisibility? = nil,
        parallaxDepth: WEVector2? = nil,
        color: WEVector3? = nil,
        alpha: Double? = nil,
        kind: SceneObjectKind = .unknown,
        image: String? = nil,
        particle: String? = nil,
        text: String? = nil,
        sounds: [String] = [],
        material: String? = nil,
        effects: [SceneEffect] = [],
        scripts: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.angles = angles
        self.scale = scale
        self.size = size
        self.visible = visible
        self.parallaxDepth = parallaxDepth
        self.color = color
        self.alpha = alpha
        self.kind = kind
        self.image = image
        self.particle = particle
        self.text = text
        self.sounds = sounds
        self.material = material
        self.effects = effects
        self.scripts = scripts
    }

    public init(from decoder: Decoder) throws {
        let object = try CaseInsensitiveContainer(from: decoder)

        id = object.int("id")
        name = object.string("name")
        origin = object.value(WEVector3.self, "origin")
        angles = object.value(WEVector3.self, "angles")
        scale = object.value(WEVector3.self, "scale")
        size = object.value(WEVector2.self, "size")
        visible = object.value(SceneVisibility.self, "visible")
        parallaxDepth = object.value(WEVector2.self, "parallaxDepth")
        color = object.value(WEVector3.self, "color")
        alpha = object.double("alpha")

        // Scripted properties are rare, so this scans a fixed short list rather than walking
        // every key on every object of every scene.
        var scripts: [String: String] = [:]
        for property in ["alpha", "origin", "angles", "scale", "color", "size"] {
            if let body = object.script(property) { scripts[property] = body }
        }
        self.scripts = scripts

        image = object.string("image")
        particle = object.string("particle")
        text = object.string("text")
        sounds = object.stringArray("sound") ?? []
        material = object.string("material")
        effects = object.array(SceneEffect.self, "effects") ?? []

        if object.has("image") {
            kind = .image
        } else if object.has("particle") {
            kind = .particle
        } else if object.has("sound") {
            kind = .sound
        } else if object.has("text") {
            kind = .text
        } else {
            kind = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeIfPresent(id, "id")
        try container.encodeIfPresent(name, "name")
        try container.encodeIfPresent(origin, "origin")
        try container.encodeIfPresent(angles, "angles")
        try container.encodeIfPresent(scale, "scale")
        try container.encodeIfPresent(size, "size")
        try container.encodeIfPresent(visible, "visible")
        try container.encodeIfPresent(parallaxDepth, "parallaxDepth")
        try container.encodeIfPresent(color, "color")
        try container.encodeIfPresent(alpha, "alpha")
        try container.encodeIfPresent(image, "image")
        try container.encodeIfPresent(particle, "particle")
        try container.encodeIfPresent(text, "text")
        if !sounds.isEmpty { try container.encode(sounds, forKey: AnyCodingKey("sound")) }
        try container.encodeIfPresent(material, "material")
        if !effects.isEmpty { try container.encode(effects, forKey: AnyCodingKey("effects")) }
    }
}

/// The `camera` root of `scene.json`. Scene wallpapers use an orthographic camera; `fov`
/// is present but only meaningful for the perspective variant.
public struct SceneCamera: Sendable, Hashable, Codable {
    public var center: WEVector3?
    public var eye: WEVector3?
    public var up: WEVector3?
    public var fov: Double?

    public init(center: WEVector3? = nil, eye: WEVector3? = nil, up: WEVector3? = nil, fov: Double? = nil) {
        self.center = center
        self.eye = eye
        self.up = up
        self.fov = fov
    }

    public init(from decoder: Decoder) throws {
        let object = try CaseInsensitiveContainer(from: decoder)
        center = object.value(WEVector3.self, "center")
        eye = object.value(WEVector3.self, "eye")
        up = object.value(WEVector3.self, "up")
        fov = object.double("fov")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeIfPresent(center, "center")
        try container.encodeIfPresent(eye, "eye")
        try container.encodeIfPresent(up, "up")
        try container.encodeIfPresent(fov, "fov")
    }
}

/// Fixed pixel dimensions of the orthographic projection — effectively the scene's
/// authoring resolution, which everything else is laid out against.
public struct OrthogonalProjection: Sendable, Hashable, Codable {
    public var width: Int?
    public var height: Int?

    public init(width: Int? = nil, height: Int? = nil) {
        self.width = width
        self.height = height
    }

    public init(from decoder: Decoder) throws {
        let object = try CaseInsensitiveContainer(from: decoder)
        width = object.int("width")
        height = object.int("height")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeIfPresent(width, "width")
        try container.encodeIfPresent(height, "height")
    }
}

/// The `general` root of `scene.json`: scene-wide lighting, background and camera
/// behaviour. Modelled as the subset the renderer consumes; unrecognised keys are ignored.
public struct SceneGeneral: Sendable, Hashable, Codable {
    public var ambientColor: WEVector3?
    public var skylightColor: WEVector3?
    public var clearColor: WEVector3?
    public var bloom: Bool?
    public var bloomStrength: Double?
    public var bloomThreshold: Double?
    public var cameraFade: Bool?
    public var cameraParallax: Bool?
    public var cameraParallaxAmount: Double?
    public var cameraParallaxDelay: Double?
    public var cameraParallaxMouseInfluence: Double?
    public var cameraShake: Bool?
    public var orthogonalProjection: OrthogonalProjection?
    public var zoom: Double?

    public init() {}

    public init(from decoder: Decoder) throws {
        let object = try CaseInsensitiveContainer(from: decoder)
        ambientColor = object.value(WEVector3.self, "ambientcolor")
        skylightColor = object.value(WEVector3.self, "skylightcolor")
        clearColor = object.value(WEVector3.self, "clearcolor")
        bloom = object.bool("bloom")
        bloomStrength = object.double("bloomstrength")
        bloomThreshold = object.double("bloomthreshold")
        cameraFade = object.bool("camerafade")
        cameraParallax = object.bool("cameraparallax")
        cameraParallaxAmount = object.double("cameraparallaxamount")
        cameraParallaxDelay = object.double("cameraparallaxdelay")
        cameraParallaxMouseInfluence = object.double("cameraparallaxmouseinfluence")
        cameraShake = object.bool("camerashake")
        orthogonalProjection = object.value(OrthogonalProjection.self, "orthogonalprojection")
        zoom = object.double("zoom")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeIfPresent(ambientColor, "ambientcolor")
        try container.encodeIfPresent(skylightColor, "skylightcolor")
        try container.encodeIfPresent(clearColor, "clearcolor")
        try container.encodeIfPresent(bloom, "bloom")
        try container.encodeIfPresent(bloomStrength, "bloomstrength")
        try container.encodeIfPresent(bloomThreshold, "bloomthreshold")
        try container.encodeIfPresent(cameraFade, "camerafade")
        try container.encodeIfPresent(cameraParallax, "cameraparallax")
        try container.encodeIfPresent(cameraParallaxAmount, "cameraparallaxamount")
        try container.encodeIfPresent(cameraParallaxDelay, "cameraparallaxdelay")
        try container.encodeIfPresent(cameraParallaxMouseInfluence, "cameraparallaxmouseinfluence")
        try container.encodeIfPresent(cameraShake, "camerashake")
        try container.encodeIfPresent(orthogonalProjection, "orthogonalprojection")
        try container.encodeIfPresent(zoom, "zoom")
    }
}

/// `scene.json` — the scene graph at the root of a Scene wallpaper's package.
///
/// One malformed object does not discard the scene: `objects` is decoded element-wise and
/// entries that fail are dropped, which is the difference between a wallpaper that renders
/// with one layer missing and one that does not render at all.
public struct SceneDocument: Sendable, Hashable, Codable {

    public var camera: SceneCamera?
    public var general: SceneGeneral?
    public var objects: [SceneObject]

    public init(camera: SceneCamera? = nil, general: SceneGeneral? = nil, objects: [SceneObject] = []) {
        self.camera = camera
        self.general = general
        self.objects = objects
    }

    public init(from decoder: Decoder) throws {
        let root = try CaseInsensitiveContainer(from: decoder)
        camera = root.value(SceneCamera.self, "camera")
        general = root.value(SceneGeneral.self, "general")
        objects = root.array(SceneObject.self, "objects") ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeIfPresent(camera, "camera")
        try container.encodeIfPresent(general, "general")
        try container.encode(objects, forKey: AnyCodingKey("objects"))
    }

    // MARK: - Loading

    /// Decodes a scene, tolerating a UTF-8 BOM and NUL padding.
    public init(data: Data) throws {
        do {
            self = try JSONDecoder().decode(SceneDocument.self, from: sanitizedJSONData(data))
        } catch let error as DecodingError {
            throw WEError.corruptField("scene.json: \(error.weSummary)")
        }
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    /// Convenience for the common "load the scene out of the package" path.
    public init(package: PKGArchive, path: String = "scene.json") throws {
        try self.init(data: try package.data(for: path))
    }

    /// Objects of a given kind, in declaration order.
    public func objects(ofKind kind: SceneObjectKind) -> [SceneObject] {
        objects.filter { $0.kind == kind }
    }
}
