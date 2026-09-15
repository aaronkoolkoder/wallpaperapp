import Foundation

/// A `CodingKey` for containers whose keys are data rather than schema — the
/// `general.properties` dictionary, whose keys are wallpaper-defined property names.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    init(_ string: String) { self.stringValue = string }
}

/// Element wrapper that turns a failed decode into `nil` instead of a thrown error.
///
/// The point is unkeyed containers: `try?` around `UnkeyedDecodingContainer.decode` does
/// not reliably advance the cursor past the bad element, so a per-element `try?` risks a
/// stalled loop. Decoding `[Failable<T>]` always consumes exactly one element per entry,
/// which is what "one malformed object must not discard the whole scene" needs.
struct Failable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

// MARK: - Lenient scalar decoding
//
// Real Workshop `project.json` files are written by several generations of the editor and
// by hand. The same field shows up as `1`, `"1"`, `1.0` and `true` across the corpus, so
// every scalar read here accepts any JSON primitive that has an unambiguous reading and
// returns `nil` rather than throwing when it does not.

extension KeyedDecodingContainer {

    func lenientString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return String(value) }
        return nil
    }

    func lenientDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value ? 1 : 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }

    func lenientInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = lenientDouble(key), value.isFinite { return Int(value) }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// Accepts either a JSON array of strings or a single bare string, which is how
    /// `tags` and sound-object file lists both appear in the wild.
    func lenientStringArray(_ key: Key) -> [String]? {
        if let values = try? decodeIfPresent([String].self, forKey: key) { return values }
        if let single = try? decodeIfPresent(String.self, forKey: key) { return [single] }
        if let mixed = try? decodeIfPresent([Failable<String>].self, forKey: key) {
            return mixed.compactMap(\.value)
        }
        return nil
    }

    /// Decodes a value that may be absent, null, or the wrong shape entirely.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// Strips a UTF-8 BOM and trailing NUL padding.
///
/// A meaningful number of Workshop `project.json` files are written by Windows tooling
/// that emits a BOM, and a few are NUL-padded to a block boundary. `JSONDecoder` rejects
/// both, which would otherwise make an entirely valid wallpaper unreadable.
func sanitizedJSONData(_ data: Data) -> Data {
    var bytes = data
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
        bytes = bytes.dropFirst(3)
    }
    while let last = bytes.last, last == 0x00 || last == 0x0A || last == 0x0D || last == 0x20 || last == 0x09 {
        bytes = bytes.dropLast()
    }
    return Data(bytes)
}

/// A keyed container whose lookups ignore key casing.
///
/// `scene.json` is not consistent about it: `parallaxDepth` is camel-cased while
/// `clearcolor` and `bloomstrength` beside it are not, and older editor versions differ
/// again. Rather than enumerate every observed spelling, the container indexes whatever
/// keys the object actually has and matches case-insensitively.
struct CaseInsensitiveContainer {
    private let container: KeyedDecodingContainer<AnyCodingKey>
    private let keys: [String: AnyCodingKey]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var keys: [String: AnyCodingKey] = [:]
        keys.reserveCapacity(container.allKeys.count)
        for key in container.allKeys { keys[key.stringValue.lowercased()] = key }
        self.container = container
        self.keys = keys
    }

    /// Whether the object carries this key at all — used to discriminate scene object
    /// kinds, which are identified by key presence rather than by a `type` field.
    func has(_ name: String) -> Bool { keys[name.lowercased()] != nil }

    func value<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let key = keys[name.lowercased()] else { return nil }
        return (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    func string(_ name: String) -> String? {
        guard let key = keys[name.lowercased()] else { return nil }
        return container.lenientString(key)
    }

    func double(_ name: String) -> Double? {
        guard let key = keys[name.lowercased()] else { return nil }
        return container.lenientDouble(key)
    }

    func int(_ name: String) -> Int? {
        guard let key = keys[name.lowercased()] else { return nil }
        return container.lenientInt(key)
    }

    func bool(_ name: String) -> Bool? {
        guard let key = keys[name.lowercased()] else { return nil }
        return container.lenientBool(key)
    }

    /// Extract a SceneScript body from a property written in object form.
    ///
    /// Wallpaper Engine writes an animated property either as a plain value (`"alpha": 1`) or
    /// as an object carrying a script alongside its initial value
    /// (`"alpha": {"value": 1, "script": "..."}`). Callers read the plain value through the
    /// normal accessors, which already tolerate the object form returning nil.
    ///
    /// - TODO(verify): the object shape is inferred from the format's general structure rather
    ///   than confirmed against real Workshop content, which this project has none of yet. The
    ///   extraction is deliberately permissive so an unexpected shape yields no script rather
    ///   than failing the wallpaper.
    func script(_ name: String) -> String? {
        struct ScriptCarrier: Decodable {
            var script: String?
            private enum CodingKeys: String, CodingKey { case script }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                script = try? container.decodeIfPresent(String.self, forKey: .script)
            }
        }
        guard let carrier = value(ScriptCarrier.self, name), let body = carrier.script,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return body
    }

    func stringArray(_ name: String) -> [String]? {
        guard let key = keys[name.lowercased()] else { return nil }
        return container.lenientStringArray(key)
    }

    /// Decodes an array element-wise, dropping entries that fail. See ``Failable``.
    func array<T: Decodable>(_ type: T.Type, _ name: String) -> [T]? {
        value([Failable<T>].self, name)?.compactMap(\.value)
    }
}

extension KeyedEncodingContainer where Key == AnyCodingKey {
    mutating func encodeIfPresent<T: Encodable>(_ value: T?, _ name: String) throws {
        guard let value else { return }
        try encode(value, forKey: AnyCodingKey(name))
    }
}
