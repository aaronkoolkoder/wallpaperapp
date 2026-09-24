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
    /// Bound to one of the wallpaper's user properties.
    ///
    /// `condition` nil means the property is itself a checkbox. Otherwise the property is a
    /// list, and the object shows while the option whose value is `condition` is chosen — how
    /// an author offers "style 1 / style 2" by keeping every variant in the scene and showing
    /// one. `value` is what the editor showed when the scene was saved, which is also what the
    /// user sees until they change the property.
    case userProperty(name: String, condition: String?, value: Bool)

    /// Value to use before any expression has been evaluated. Objects default to visible,
    /// matching the editor's own behaviour for an unbound expression.
    public var staticValue: Bool {
        switch self {
        case let .constant(value): return value
        case .expression: return true
        case let .userProperty(_, _, value): return value
        }
    }

    /// Whether this is shown given the user's current settings, keyed as `project.json`
    /// keys them. A property the user has not touched keeps the value it was saved with.
    public func isVisible(with properties: [String: DynamicValue]) -> Bool {
        guard case let .userProperty(name, condition, value) = self else { return staticValue }
        guard let current = properties[name] else { return value }
        guard let condition else { return current.boolValue ?? value }
        return Self.optionText(current) == condition
    }

    /// Whether this can change while the wallpaper runs.
    public var isUserBound: Bool {
        if case .userProperty = self { return true }
        return false
    }

    /// A list property's value as the text a condition is written in: `2`, not `2.0`.
    private static func optionText(_ value: DynamicValue) -> String? {
        switch value {
        case let .string(text): return text
        case let .number(number):
            return number.rounded() == number ? String(Int(number)) : String(number)
        case let .bool(flag): return flag ? "1" : "0"
        default: return nil
        }
    }

    private enum BindingKeys: String, CodingKey { case user, value, name, condition }

    public init(from decoder: Decoder) throws {
        // The bound form is an object. It used to fall through every case below and be read as
        // "no visibility given" — visible — so an effect the author shipped switched *off*
        // was drawn anyway: 38 objects and effects across the test library, film grain among
        // them, which whited out the scenes it was left running in.
        if let binding = try? decoder.container(keyedBy: BindingKeys.self),
           binding.contains(.value) {
            let value = Self.flag(in: binding) ?? true
            if let name = try? binding.decode(String.self, forKey: .user) {
                self = .userProperty(name: name, condition: nil, value: value)
            } else if let user = try? binding.nestedContainer(keyedBy: BindingKeys.self, forKey: .user),
                      let name = try? user.decode(String.self, forKey: .name) {
                let condition = (try? user.decode(String.self, forKey: .condition))
                    ?? (try? user.decode(Double.self, forKey: .condition)).map { Self.optionText(.number($0)) ?? "" }
                self = .userProperty(name: name, condition: condition, value: value)
            } else {
                // Driven by a script rather than a property. What the editor saved is the best
                // available answer until scripts can drive visibility.
                self = .constant(value)
            }
            return
        }

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
                .init(codingPath: container.codingPath, debugDescription: "expected a bool, an expression, or a property binding")
            )
        }
    }

    private static func flag(in binding: KeyedDecodingContainer<BindingKeys>) -> Bool? {
        if let value = try? binding.decode(Bool.self, forKey: .value) { return value }
        if let value = try? binding.decode(Double.self, forKey: .value) { return value != 0 }
        if let value = try? binding.decode(String.self, forKey: .value) {
            return ["true", "1", "yes"].contains(value.lowercased())
        }
        return nil
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .constant(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .expression(text):
            var container = encoder.singleValueContainer()
            try container.encode(text)
        case let .userProperty(name, condition, value):
            var container = encoder.container(keyedBy: BindingKeys.self)
            if let condition {
                var user = container.nestedContainer(keyedBy: BindingKeys.self, forKey: .user)
                try user.encode(name, forKey: .name)
                try user.encode(condition, forKey: .condition)
            } else {
                try container.encode(name, forKey: .user)
            }
            try container.encode(value, forKey: .value)
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
    /// This instance's own settings for each of the effect's passes, index for index.
    public var passes: [SceneEffectPass]

    public init(
        id: Int? = nil, name: String? = nil, file: String? = nil,
        visible: SceneVisibility? = nil, passes: [SceneEffectPass] = []
    ) {
        self.id = id
        self.name = name
        self.file = file
        self.visible = visible
        self.passes = passes
    }

    public init(from decoder: Decoder) throws {
        let object = try CaseInsensitiveContainer(from: decoder)
        id = object.int("id")
        name = object.string("name")
        file = object.string("file")
        visible = object.value(SceneVisibility.self, "visible")
        passes = object.value([SceneEffectPass].self, "passes") ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeIfPresent(id, "id")
        try container.encodeIfPresent(name, "name")
        try container.encodeIfPresent(file, "file")
        try container.encodeIfPresent(visible, "visible")
        if !passes.isEmpty { try container.encodeIfPresent(passes, "passes") }
    }
}

/// What one placed instance of an effect changes about one of its passes.
///
/// The effect file describes the effect in general; this is how the author tuned it *here* —
/// the strength and speed they dialled in, the variant they picked, and the mask they painted
/// so that only the hair sways or only the water ripples. Ignored, every effect runs on its
/// shader's defaults over the whole layer: 350 of the 360 effect instances in the test library
/// carry tuned values, and 221 carry a painted mask.
public struct SceneEffectPass: Sendable, Hashable, Codable {
    public var combos: [String: Int]
    /// Keyed by the uniform's `material` name, as the material's own values are.
    public var constantShaderValues: [String: DynamicValue]
    /// The user property driving a constant, where the author bound one, keyed the same way.
    public var constantBindings: [String: String]
    /// Entry `N` is the texture for sampler `g_TextureN`; nil leaves that sampler as it was.
    public var textures: [String?]

    public init(
        combos: [String: Int] = [:],
        constantShaderValues: [String: DynamicValue] = [:],
        constantBindings: [String: String] = [:],
        textures: [String?] = []
    ) {
        self.combos = combos
        self.constantShaderValues = constantShaderValues
        self.constantBindings = constantBindings
        self.textures = textures
    }

    /// A pass constant as the format writes it.
    ///
    /// Plain until the author binds it to one of the wallpaper's own settings, and an object
    /// carrying the same value beside that binding from then on — the same two spellings every
    /// other property in `scene.json` has. Read as a plain value only, a bound one decoded as
    /// nothing and the shader's own default stood in for it: the tint on Chainsaw Man's walls
    /// defaults to "1 0 0", so both walls of the wallpaper rendered pure red.
    private struct Constant: Decodable {
        var value: DynamicValue
        var user: String?

        init(from decoder: Decoder) throws {
            if let plain = try? DynamicValue(from: decoder), plain != .null {
                value = plain
                user = nil
                return
            }
            let object = try CaseInsensitiveContainer(from: decoder)
            value = object.value(DynamicValue.self, "value") ?? .null
            user = object.string("user")
        }
    }

    public init(from decoder: Decoder) throws {
        let object = try CaseInsensitiveContainer(from: decoder)
        combos = object.value([String: Int].self, "combos") ?? [:]
        let constants = object.value([String: Constant].self, "constantshadervalues") ?? [:]
        constantShaderValues = constants.compactMapValues { $0.value == .null ? nil : $0.value }
        constantBindings = constants.compactMapValues(\.user)
        textures = object.value([String?].self, "textures") ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeIfPresent(combos, "combos")
        try container.encodeIfPresent(constantShaderValues, "constantshadervalues")
        try container.encodeIfPresent(constantBindings, "constantbindings")
        try container.encodeIfPresent(textures, "textures")
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
    /// This instance's own tuning of that system, when it carries one.
    public var particleOverrides: ParticleOverrides?
    /// Literal string for a text object.
    public var text: String?
    /// Audio file references. Sound objects store an array; a bare string is accepted too.
    public var sounds: [String]

    /// Direct material reference, when the object overrides the model's own material.
    public var material: String?

    /// Ordered effect chain applied to this object's rendered output.
    public var effects: [SceneEffect]
    /// Font name for a text object, as the wallpaper names it.
    public var font: String?
    /// Point size in scene units.
    public var fontSize: Double?
    /// `left`, `center`, `right`.
    public var horizontalAlign: String?
    /// `top`, `center`, `bottom`.
    public var verticalAlign: String?
    /// Outline/shadow thickness, when the text declares one.
    public var outlineSize: Double?
    /// Outline colour, 0-1 components.
    public var outlineColor: WEVector3?
    /// SceneScript bodies keyed by the property they animate: `alpha`, `origin`, `angles`,
    /// `scale`, `color`, `size`, `text`. Empty for the overwhelming majority of objects.
    public var scripts: [String: String]
    /// The settings each script declares, as this wallpaper saved them, keyed like ``scripts``.
    /// A clock's 24-hour switch and separator live here.
    public var scriptProperties: [String: [String: DynamicValue]]
    /// Timeline animations keyed by the property they drive: `alpha`, `origin`, `angles`,
    /// `scale`, `color`.
    public var animations: [String: PropertyAnimation]

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
        particleOverrides: ParticleOverrides? = nil,
        text: String? = nil,
        sounds: [String] = [],
        material: String? = nil,
        effects: [SceneEffect] = [],
        scripts: [String: String] = [:],
        scriptProperties: [String: [String: DynamicValue]] = [:],
        animations: [String: PropertyAnimation] = [:],
        font: String? = nil,
        fontSize: Double? = nil,
        horizontalAlign: String? = nil,
        verticalAlign: String? = nil,
        outlineSize: Double? = nil,
        outlineColor: WEVector3? = nil
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
        self.particleOverrides = particleOverrides
        self.text = text
        self.sounds = sounds
        self.material = material
        self.effects = effects
        self.scripts = scripts
        self.scriptProperties = scriptProperties
        self.animations = animations
        self.font = font
        self.fontSize = fontSize
        self.horizontalAlign = horizontalAlign
        self.verticalAlign = verticalAlign
        self.outlineSize = outlineSize
        self.outlineColor = outlineColor
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
        var scriptProperties: [String: [String: DynamicValue]] = [:]
        for property in ["alpha", "origin", "angles", "scale", "color", "size", "text"] {
            guard let body = object.script(property) else { continue }
            scripts[property] = body
            let saved = object.scriptProperties(property)
            if !saved.isEmpty { scriptProperties[property] = saved }
        }
        self.scripts = scripts
        self.scriptProperties = scriptProperties

        var animations: [String: PropertyAnimation] = [:]
        for property in ["alpha", "origin", "angles", "scale", "color"] {
            if let animation = object.animation(property), !animation.channels.isEmpty {
                animations[property] = animation
            }
        }
        self.animations = animations

        font = object.string("font")
        // `pointsize` is what every text object in a real 59-scene library uses. `size` is the
        // text box, written as a vector, so it never read as a number anyway.
        fontSize = object.double("pointsize") ?? object.double("fontsize")
        verticalAlign = object.string("verticalalign")
        horizontalAlign = object.string("horizontalalign") ?? object.string("align")
        outlineSize = object.double("outlinesize")
        outlineColor = object.value(WEVector3.self, "outlinecolor")

        image = object.string("image")
        particle = object.string("particle")
        particleOverrides = object.value(ParticleOverrides.self, "instanceoverride")
            .flatMap { $0.isEmpty ? nil : $0 }
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

/// A property animated on a timeline in the editor, rather than by script.
///
/// Written inside the property's object form, beside its value:
///
/// ```json
/// "alpha": {"value": 1, "animation": {
///     "c0": [{"frame": 0, "value": 1}, {"frame": 90, "value": 1}, {"frame": 120, "value": 0}],
///     "options": {"fps": 30, "length": 120, "mode": "single"}}}
/// ```
///
/// One channel per component (`c0`…`c2`). Keyframes also carry Bézier handles, which are read
/// past: the curve between keys is drawn straight.
public struct PropertyAnimation: Sendable, Hashable, Decodable {
    public enum Mode: String, Sendable, Hashable {
        /// Wrap around to the start.
        case loop
        /// Play once and hold the last value.
        case single
        /// Play forwards, then backwards.
        case mirror
    }

    public struct Keyframe: Sendable, Hashable {
        public var frame: Double
        public var value: Double
        public init(frame: Double, value: Double) {
            self.frame = frame
            self.value = value
        }
    }

    public var channels: [[Keyframe]]
    public var framesPerSecond: Double
    /// Timeline length, in frames.
    public var length: Double
    public var mode: Mode

    public init(channels: [[Keyframe]], framesPerSecond: Double, length: Double, mode: Mode) {
        self.channels = channels
        self.framesPerSecond = framesPerSecond
        self.length = length
        self.mode = mode
    }

    public init(from decoder: Decoder) throws {
        struct RawKeyframe: Decodable {
            var frame: Double?
            var value: Double?
        }
        struct Options: Decodable {
            var fps: Double?
            var length: Double?
            var mode: String?
        }
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var channels: [[Keyframe]] = []
        for index in 0 ..< 4 {
            guard let raw = try? container.decodeIfPresent(
                [Failable<RawKeyframe>].self, forKey: AnyCodingKey("c\(index)")
            ) else { break }
            let keys = raw.compactMap(\.value).compactMap { key -> Keyframe? in
                guard let frame = key.frame, let value = key.value,
                      frame.isFinite, value.isFinite else { return nil }
                return Keyframe(frame: frame, value: value)
            }
            channels.append(keys.sorted { $0.frame < $1.frame })
        }
        let options = try? container.decodeIfPresent(Options.self, forKey: AnyCodingKey("options"))
        self.channels = channels
        framesPerSecond = options?.fps ?? 30
        length = options?.length ?? (channels.flatMap { $0 }.map(\.frame).max() ?? 0)
        mode = options?.mode.flatMap { Mode(rawValue: $0.lowercased()) } ?? .loop
    }

    /// Each channel's value `seconds` into the animation.
    public func values(at seconds: Double) -> [Double] {
        var frame = seconds * framesPerSecond
        if length > 0, frame.isFinite {
            switch mode {
            case .loop:
                frame = frame.truncatingRemainder(dividingBy: length)
                if frame < 0 { frame += length }
            case .single:
                frame = min(max(frame, 0), length)
            case .mirror:
                let period = length * 2
                var position = frame.truncatingRemainder(dividingBy: period)
                if position < 0 { position += period }
                frame = position > length ? period - position : position
            }
        }
        return channels.map { Self.interpolate($0, at: frame) }
    }

    private static func interpolate(_ keys: [Keyframe], at frame: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if frame <= first.frame { return first.value }
        if frame >= last.frame { return last.value }
        for (from, to) in zip(keys, keys.dropFirst()) where frame <= to.frame {
            let span = to.frame - from.frame
            guard span > 0 else { return to.value }
            return from.value + (to.value - from.value) * (frame - from.frame) / span
        }
        return last.value
    }
}
