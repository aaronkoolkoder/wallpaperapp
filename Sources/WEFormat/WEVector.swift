import Foundation

/// A three-component vector as Wallpaper Engine stores it.
///
/// Scene JSON writes vectors as **space-separated strings** — `"0.5 1.0 0.0"` — not as
/// JSON arrays, and mixes in array form for some fields depending on which version of the
/// editor wrote the file. Both are accepted on decode; encoding always emits the string
/// form, which is what the editor produces.
public struct WEVector3: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(x: Double, y: Double, z: Double) { self.init(x, y, z) }

    public static let zero = WEVector3(0, 0, 0)
    public static let one = WEVector3(1, 1, 1)

    public var components: [Double] { [x, y, z] }

    /// Parses the `"x y z"` string form.
    ///
    /// Separators may be any run of whitespace or commas — hand-edited wallpapers use
    /// both. Fewer than three components are zero-filled rather than rejected, since a
    /// truncated vector in one object should not fail the whole scene; more than three is
    /// an error, because that is a different type being mis-read.
    public init(parsing text: String) throws {
        let parts = WEVectorParsing.components(of: text)
        guard !parts.isEmpty, parts.count <= 3 else {
            throw WEError.corruptField("\"\(text)\" is not a 3-component vector")
        }
        var values: [Double] = []
        for part in parts {
            guard let value = Double(part) else {
                throw WEError.corruptField("\"\(text)\" has a non-numeric component \"\(part)\"")
            }
            values.append(value)
        }
        while values.count < 3 { values.append(0) }
        self.init(values[0], values[1], values[2])
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            do {
                self = try WEVector3(parsing: text)
            } catch {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "\"\(text)\" is not a 3-component vector"
                )
            }
            return
        }
        if let array = try? container.decode([Double].self) {
            guard !array.isEmpty, array.count <= 3 else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "expected 1…3 components, found \(array.count)"
                )
            }
            let padded = array + Array(repeating: 0, count: 3 - array.count)
            self.init(padded[0], padded[1], padded[2])
            return
        }
        throw DecodingError.typeMismatch(
            WEVector3.self,
            .init(codingPath: container.codingPath, debugDescription: "expected \"x y z\" or [x, y, z]")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode("\(x) \(y) \(z)")
    }
}

/// A two-component vector. Used for `parallaxDepth` and texture coordinates, and decoded
/// exactly like ``WEVector3``.
public struct WEVector2: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(x: Double, y: Double) { self.init(x, y) }

    public static let zero = WEVector2(0, 0)
    public static let one = WEVector2(1, 1)

    public var components: [Double] { [x, y] }

    /// Parses the `"x y"` string form. See ``WEVector3/init(parsing:)``.
    public init(parsing text: String) throws {
        let parts = WEVectorParsing.components(of: text)
        guard !parts.isEmpty, parts.count <= 2 else {
            throw WEError.corruptField("\"\(text)\" is not a 2-component vector")
        }
        var values: [Double] = []
        for part in parts {
            guard let value = Double(part) else {
                throw WEError.corruptField("\"\(text)\" has a non-numeric component \"\(part)\"")
            }
            values.append(value)
        }
        while values.count < 2 { values.append(0) }
        self.init(values[0], values[1])
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            do {
                self = try WEVector2(parsing: text)
            } catch {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "\"\(text)\" is not a 2-component vector"
                )
            }
            return
        }
        if let array = try? container.decode([Double].self) {
            guard !array.isEmpty, array.count <= 2 else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "expected 1…2 components, found \(array.count)"
                )
            }
            let padded = array + Array(repeating: 0, count: 2 - array.count)
            self.init(padded[0], padded[1])
            return
        }
        throw DecodingError.typeMismatch(
            WEVector2.self,
            .init(codingPath: container.codingPath, debugDescription: "expected \"x y\" or [x, y]")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode("\(x) \(y)")
    }
}

enum WEVectorParsing {
    /// Splits on whitespace and commas, dropping empty runs.
    static func components(of text: String) -> [Substring] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
    }
}
