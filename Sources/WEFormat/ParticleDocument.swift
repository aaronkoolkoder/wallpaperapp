import Foundation

/// A named, loosely-typed node in a particle definition.
///
/// Wallpaper Engine's emitters, initializers and operators all share one shape: a `name`
/// selecting the behaviour, plus an open bag of parameters whose meaning depends on that name.
/// Modelling them as one permissive type rather than an exhaustive enum is deliberate — there
/// are dozens of behaviours, content in the wild uses ones not documented anywhere, and a strict
/// decoder would fail the whole wallpaper over a single unrecognised node.
public struct ParticleNode: Sendable, Hashable, Codable {
    public var name: String
    public var id: Int?
    /// Everything else, kept as decoded values so a behaviour can read what it needs.
    public var parameters: [String: DynamicValue]

    public init(name: String, id: Int? = nil, parameters: [String: DynamicValue] = [:]) {
        self.name = name
        self.id = id
        self.parameters = parameters
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var parameters: [String: DynamicValue] = [:]
        var name = ""
        var id: Int?

        for key in container.allKeys {
            switch key.stringValue {
            case "name":
                name = (try? container.decode(String.self, forKey: key)) ?? ""
            case "id":
                id = try? container.decode(Int.self, forKey: key)
            default:
                if let value = try? container.decode(DynamicValue.self, forKey: key) {
                    parameters[key.stringValue] = value
                }
            }
        }
        self.name = name.lowercased()
        self.id = id
        self.parameters = parameters
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        if let key = AnyKey(stringValue: "name") { try container.encode(name, forKey: key) }
        for (key, value) in parameters {
            if let codingKey = AnyKey(stringValue: key) {
                try container.encode(value, forKey: codingKey)
            }
        }
    }

    // MARK: - Typed parameter access

    public func double(_ key: String) -> Double? { parameters[key]?.doubleValue }
    public func float(_ key: String) -> Float? { parameters[key]?.doubleValue.map(Float.init) }
    public func bool(_ key: String) -> Bool? { parameters[key]?.boolValue }
    public func string(_ key: String) -> String? { parameters[key]?.stringValue }

    /// Vectors arrive either as a `"x y z"` string or as a bare number meaning all components.
    public func vector(_ key: String) -> WEVector3? {
        guard let value = parameters[key] else { return nil }
        if let vector = value.vector3Value { return vector }
        if let scalar = value.doubleValue { return WEVector3(scalar, scalar, scalar) }
        return nil
    }
}

/// A particle system definition, as found at `particles/<name>.json`.
public struct ParticleDocument: Sendable, Hashable, Codable {
    /// Material used to draw each particle.
    public var material: String?
    /// Upper bound on live particles. Respected strictly — content can ask for a great deal.
    public var maxCount: Int
    public var startTime: Double?
    public var emitters: [ParticleNode]
    public var initializers: [ParticleNode]
    public var operators: [ParticleNode]
    /// Particle systems carried along with this one, by path.
    public var children: [String]

    public init(
        material: String? = nil, maxCount: Int = 100, startTime: Double? = nil,
        emitters: [ParticleNode] = [], initializers: [ParticleNode] = [],
        operators: [ParticleNode] = [], children: [String] = []
    ) {
        self.material = material
        self.maxCount = maxCount
        self.startTime = startTime
        self.emitters = emitters
        self.initializers = initializers
        self.operators = operators
        self.children = children
    }

    /// A child as the format writes it: an id and the path to another definition.
    private struct ChildReference: Codable {
        var name: String?
    }

    private enum CodingKeys: String, CodingKey {
        case material, maxcount, starttime, emitter, initializer, `operator`, children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        material = try container.decodeIfPresent(String.self, forKey: .material)
        startTime = try container.decodeIfPresent(Double.self, forKey: .starttime)

        // Clamp rather than trust. A wallpaper declaring a million particles would allocate
        // gigabytes and stall the render thread; this content is untrusted third-party data.
        let declared = try container.decodeIfPresent(Int.self, forKey: .maxcount) ?? 100
        maxCount = min(max(0, declared), 20_000)

        // The keys are singular in the format even though they hold arrays.
        emitters = try container.decodeIfPresent([ParticleNode].self, forKey: .emitter) ?? []
        initializers = try container.decodeIfPresent([ParticleNode].self, forKey: .initializer) ?? []
        operators = try container.decodeIfPresent([ParticleNode].self, forKey: .operator) ?? []

        // A second sheet of leaves in a drift, the glow under an ember: content builds one
        // effect out of a parent and its children, and a library that ignores the children
        // draws half of it. The key is null as often as it is absent.
        children = ((try? container.decodeIfPresent([ChildReference].self, forKey: .children)) ?? [])?
            .compactMap(\.name) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(material, forKey: .material)
        try container.encode(maxCount, forKey: .maxcount)
        try container.encodeIfPresent(startTime, forKey: .starttime)
        try container.encode(emitters, forKey: .emitter)
        try container.encode(initializers, forKey: .initializer)
        try container.encode(operators, forKey: .operator)
        try container.encode(children.map { ChildReference(name: $0) }, forKey: .children)
    }
}
