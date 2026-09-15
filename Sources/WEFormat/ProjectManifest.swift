import Foundation

/// The `type` field of `project.json`.
///
/// Matching is case-insensitive: the editor writes `"scene"` but hand-edited and older
/// manifests use `"Scene"`. Anything unrecognised is preserved in ``unknown(_:)`` rather
/// than rejected, so a new content type shows up in the library as "unsupported: X"
/// instead of failing the scan.
public enum WallpaperType: Sendable, Hashable, Codable {
    case scene
    case video
    case web
    case application
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "scene": self = .scene
        case "video": self = .video
        case "web": self = .web
        case "application": self = .application
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .scene: return "scene"
        case .video: return "video"
        case .web: return "web"
        case .application: return "application"
        case let .unknown(value): return value
        }
    }

    /// `application` wallpapers are Windows executables and are permanently out of scope;
    /// unknown types are unsupported by definition.
    public var isPlayable: Bool {
        switch self {
        case .scene, .video, .web: return true
        case .application, .unknown: return false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The kind of control a user-configurable property maps to.
///
/// The known cases cover everything the settings UI can render. Unrecognised types decode
/// into ``unknown(_:)`` and are simply not shown — never a decode failure, because one
/// exotic property must not cost the user the other twenty on the same wallpaper.
public enum WEPropertyType: Sendable, Hashable, Codable {
    case bool
    case slider
    case color
    case combo
    case text
    case file
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bool": self = .bool
        case "slider": self = .slider
        case "color": self = .color
        case "combo": self = .combo
        case "text": self = .text
        case "file": self = .file
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .bool: return "bool"
        case .slider: return "slider"
        case .color: return "color"
        case .combo: return "combo"
        case .text: return "text"
        case .file: return "file"
        case let .unknown(value): return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A property value, which is heterogeneous by design: the same `value` key holds a bool
/// for a checkbox, a number for a slider, a string for a text field and an `"r g b"`
/// triple for a colour swatch.
public enum DynamicValue: Sendable, Hashable, Codable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case vector3(WEVector3)
    case null

    public var boolValue: Bool? {
        switch self {
        case let .bool(value): return value
        case let .number(value): return value != 0
        case let .string(value): return ["true", "yes", "1"].contains(value.lowercased())
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .number(value): return value
        case let .bool(value): return value ? 1 : 0
        case let .string(value): return Double(value)
        default: return nil
        }
    }

    public var stringValue: String? {
        switch self {
        case let .string(value): return value
        case let .number(value): return String(value)
        case let .bool(value): return String(value)
        case let .vector3(value): return "\(value.x) \(value.y) \(value.z)"
        case .null: return nil
        }
    }

    /// Colour and origin values arrive as `"r g b"` strings; this promotes them on demand
    /// for callers that did not get a pre-promoted ``vector3(_:)``.
    public var vector3Value: WEVector3? {
        switch self {
        case let .vector3(value): return value
        case let .string(value): return try? WEVector3(parsing: value)
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Double].self), value.count == 3 {
            self = .vector3(WEVector3(value[0], value[1], value[2]))
        } else {
            throw DecodingError.typeMismatch(
                DynamicValue.self,
                .init(codingPath: container.codingPath, debugDescription: "unsupported property value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .vector3(value): try container.encode("\(value.x) \(value.y) \(value.z)")
        case .null: try container.encodeNil()
        }
    }
}

/// One entry of a `combo` property's dropdown.
public struct WEComboOption: Sendable, Hashable, Codable {
    public var label: String?
    public var value: DynamicValue?

    public init(label: String? = nil, value: DynamicValue? = nil) {
        self.label = label
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case label, value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = container.lenientString(.label)
        value = container.lenient(DynamicValue.self, .value)
    }
}

/// A single user-configurable wallpaper setting from `general.properties`.
///
/// Only ``type`` is treated as required, and even that falls back to
/// ``WEPropertyType/unknown(_:)``. Every other field is read leniently, because the corpus
/// disagrees with itself about whether `min`/`max`/`step` are numbers or strings.
public struct WEProperty: Sendable, Hashable, Codable {

    public var type: WEPropertyType

    /// Human-readable label. Often a localisation token such as `ui_browse_properties_x`.
    public var text: String?

    public var value: DynamicValue?

    /// Slider bounds and increment. Absent for every other control type.
    public var min: Double?
    public var max: Double?
    public var step: Double?

    /// Choices for a `combo` property.
    public var options: [WEComboOption]?

    /// Display order in the settings UI, when the wallpaper specifies one.
    public var order: Int?

    public init(
        type: WEPropertyType,
        text: String? = nil,
        value: DynamicValue? = nil,
        min: Double? = nil,
        max: Double? = nil,
        step: Double? = nil,
        options: [WEComboOption]? = nil,
        order: Int? = nil
    ) {
        self.type = type
        self.text = text
        self.value = value
        self.min = min
        self.max = max
        self.step = step
        self.options = options
        self.order = order
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, value, min, max, step, options, order
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = WEPropertyType(rawValue: container.lenientString(.type) ?? "")
        text = container.lenientString(.text)
        min = container.lenientDouble(.min)
        max = container.lenientDouble(.max)
        step = container.lenientDouble(.step)
        order = container.lenientInt(.order)

        // Options that fail individually are dropped, not fatal.
        if let raw = container.lenient([Failable<WEComboOption>].self, .options) {
            options = raw.compactMap(\.value)
        } else {
            options = nil
        }

        var decodedValue = container.lenient(DynamicValue.self, .value)
        // Colours are stored as `"r g b"`; promote them once here so the settings UI and
        // the shader binding layer do not each have to re-parse the string.
        if type == .color, case let .string(text)? = decodedValue,
           let vector = try? WEVector3(parsing: text) {
            decodedValue = .vector3(vector)
        }
        value = decodedValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(min, forKey: .min)
        try container.encodeIfPresent(max, forKey: .max)
        try container.encodeIfPresent(step, forKey: .step)
        try container.encodeIfPresent(options, forKey: .options)
        try container.encodeIfPresent(order, forKey: .order)
    }
}

/// The `general` object of `project.json`. Only `properties` is modelled; the rest of the
/// object is editor bookkeeping.
public struct WEGeneral: Sendable, Hashable, Codable {

    /// User-configurable settings, keyed by the identifier the wallpaper's shaders bind to.
    public var properties: [String: WEProperty]

    public init(properties: [String: WEProperty] = [:]) {
        self.properties = properties
    }

    private enum CodingKeys: String, CodingKey { case properties }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let nested = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .properties) else {
            properties = [:]
            return
        }
        // Decoded key by key so one malformed property does not discard the rest. A keyed
        // container can be re-read per key safely, unlike an unkeyed one.
        var decoded: [String: WEProperty] = [:]
        decoded.reserveCapacity(nested.allKeys.count)
        for key in nested.allKeys {
            if let property = try? nested.decode(WEProperty.self, forKey: key) {
                decoded[key.stringValue] = property
            }
        }
        properties = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .properties)
        for (name, property) in properties {
            try nested.encode(property, forKey: AnyCodingKey(name))
        }
    }
}

/// `project.json` — the manifest at the root of every Workshop item.
///
/// The parse is deliberately forgiving. A library scan walks hundreds of directories that
/// were produced by different editor versions over a decade, and the failure mode that
/// matters is a single odd manifest hiding an entire folder from the user. Only genuinely
/// unreadable JSON throws; everything else degrades to `nil` or a defaulted value.
public struct ProjectManifest: Sendable, Hashable, Codable {

    public var title: String
    public var description: String?
    public var type: WallpaperType
    /// Entry point relative to the item directory: `scene.pkg`, a video file, `index.html`.
    public var file: String?
    /// Preview image relative to the item directory, usually `preview.jpg` or `preview.gif`.
    public var preview: String?
    public var tags: [String]
    /// Steam's content rating: `"Everyone"`, `"Questionable"`, `"Mature"`.
    public var contentRating: String?
    public var official: Bool?
    public var visibility: String?
    public var general: WEGeneral?

    public init(
        title: String = "",
        description: String? = nil,
        type: WallpaperType = .unknown(""),
        file: String? = nil,
        preview: String? = nil,
        tags: [String] = [],
        contentRating: String? = nil,
        official: Bool? = nil,
        visibility: String? = nil,
        general: WEGeneral? = nil
    ) {
        self.title = title
        self.description = description
        self.type = type
        self.file = file
        self.preview = preview
        self.tags = tags
        self.contentRating = contentRating
        self.official = official
        self.visibility = visibility
        self.general = general
    }

    /// Convenience access to `general.properties`.
    public var properties: [String: WEProperty] { general?.properties ?? [:] }

    private enum CodingKeys: String, CodingKey {
        case title, description, type, file, preview, tags
        case contentRating = "contentrating"
        case official, visibility, general
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.lenientString(.title) ?? ""
        description = container.lenientString(.description)
        type = WallpaperType(rawValue: container.lenientString(.type) ?? "")
        file = container.lenientString(.file)
        preview = container.lenientString(.preview)
        tags = container.lenientStringArray(.tags) ?? []
        contentRating = container.lenientString(.contentRating)
        official = container.lenientBool(.official)
        visibility = container.lenientString(.visibility)
        general = container.lenient(WEGeneral.self, .general)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(file, forKey: .file)
        try container.encodeIfPresent(preview, forKey: .preview)
        if !tags.isEmpty { try container.encode(tags, forKey: .tags) }
        try container.encodeIfPresent(contentRating, forKey: .contentRating)
        try container.encodeIfPresent(official, forKey: .official)
        try container.encodeIfPresent(visibility, forKey: .visibility)
        try container.encodeIfPresent(general, forKey: .general)
    }

    // MARK: - Loading

    /// Decodes a manifest, tolerating a UTF-8 BOM and NUL padding.
    public init(data: Data) throws {
        do {
            self = try JSONDecoder().decode(ProjectManifest.self, from: sanitizedJSONData(data))
        } catch let error as DecodingError {
            throw WEError.corruptField("project.json: \(error.weSummary)")
        }
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }
}

extension DecodingError {
    /// Flattens a `DecodingError` into one loggable line for the compatibility report.
    var weSummary: String {
        switch self {
        case let .dataCorrupted(context):
            return "malformed JSON (\(context.debugDescription))"
        case let .keyNotFound(key, _):
            return "missing key \"\(key.stringValue)\""
        case let .typeMismatch(type, context):
            return "expected \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case let .valueNotFound(type, context):
            return "null \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        @unknown default:
            return "\(self)"
        }
    }
}
