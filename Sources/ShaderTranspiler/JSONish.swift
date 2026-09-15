import Foundation

// MARK: - Value model

/// A JSON-shaped value recovered from a Wallpaper Engine metadata comment.
///
/// Wallpaper Engine's in-comment metadata is *nearly* JSON but not reliably so in
/// shipped Workshop content — trailing commas, unquoted keys, single quotes and
/// truncated objects all occur. This model is deliberately order-preserving because
/// combo `options` are presented to the user in declaration order.
public enum JSONish: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONish])
    case object(JSONishObject)
}

public extension JSONish {
    /// The value as a string, only when it really is a string.
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// A number, coercing from numeric strings and booleans.
    ///
    /// Coercion matters: `"default":"0"` and `"default":0` both appear in the wild.
    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : Double(trimmed)
        default: return nil
        }
    }

    var intValue: Int? {
        guard let d = doubleValue, d.isFinite else { return nil }
        guard d >= Double(Int.min) && d <= Double(Int.max) else { return nil }
        return Int(d.rounded())
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    var arrayValue: [JSONish]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: JSONishObject? {
        if case .object(let o) = self { return o }
        return nil
    }
}

/// An order-preserving string-keyed object.
public struct JSONishObject: Sendable, Hashable {
    public private(set) var keys: [String] = []
    private var values: [String: JSONish] = [:]

    public init() {}

    public init(_ pairs: [(String, JSONish)]) {
        for (key, value) in pairs { set(key, value) }
    }

    public mutating func set(_ key: String, _ value: JSONish) {
        if values.updateValue(value, forKey: key) == nil { keys.append(key) }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    /// Case-insensitive lookup.
    ///
    /// `TODO(verify):` Wallpaper Engine's own key casing has only been observed as
    /// lowercase (`combo`, `material`, `default`). The case-insensitive fallback is
    /// defensive, not confirmed behavior.
    public func value(for key: String) -> JSONish? {
        if let direct = values[key] { return direct }
        let lowered = key.lowercased()
        for candidate in keys where candidate.lowercased() == lowered {
            return values[candidate]
        }
        return nil
    }

    /// First present key among `names`, in order.
    public func value(forAnyOf names: [String]) -> JSONish? {
        for name in names {
            if let found = value(for: name) { return found }
        }
        return nil
    }

    public var pairs: [(key: String, value: JSONish)] {
        keys.compactMap { key in values[key].map { (key: key, value: $0) } }
    }
}

// MARK: - Reading

enum JSONishParseMode: Sendable, Hashable {
    /// The text was valid JSON as Foundation understands it.
    case strict
    /// The text needed the tolerant scanner to produce anything.
    case lenient
}

struct JSONishOutcome: Sendable, Hashable {
    var value: JSONish
    var mode: JSONishParseMode
}

/// Two-stage reader for Wallpaper Engine metadata payloads.
///
/// Stage one uses `JSONSerialization` purely as a *validity gate* — it is the best-tested
/// JSON validator available and settles whether the payload was well-formed. Stage two
/// always re-reads with the ordered scanner below, because `JSONSerialization` discards
/// object key order, which combo option lists depend on.
enum JSONishReader {
    static func parse(_ text: String) -> JSONishOutcome? {
        let data = Data(text.utf8)
        let isStrictJSON = (try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )) != nil

        if isStrictJSON, let value = JSONishScanner.parse(text, mode: .strict) {
            return JSONishOutcome(value: value, mode: .strict)
        }
        if let value = JSONishScanner.parse(text, mode: .lenient) {
            return JSONishOutcome(value: value, mode: .lenient)
        }
        return nil
    }
}

/// Extracts a balanced `{ ... }` literal out of surrounding comment text.
enum JSONishExtractor {
    /// Returns the substring from the first `{` through its matching `}`.
    ///
    /// When the braces never balance — a truncated annotation, which does occur — the
    /// remainder of the text is returned so the lenient scanner still gets a chance.
    static func firstObjectLiteral(in text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0
        var quote: Character?
        var i = start
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                if ch == "\\" { i += 2; continue }
                if ch == q { quote = nil }
                i += 1
                continue
            }
            switch ch {
            case "\"", "'":
                quote = ch
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(chars[start...i]) }
            default:
                break
            }
            i += 1
        }
        return String(chars[start...])
    }
}

/// Recursive-descent reader with a strict and a tolerant mode.
///
/// In `.strict` mode this is only ever run on text `JSONSerialization` already accepted,
/// so it is a *reader*, not a validator; it does not attempt to re-litigate JSON
/// well-formedness. In `.lenient` mode it accepts trailing commas, missing commas,
/// single quotes, unquoted keys and values, `//` and `/* */` comments, and truncated
/// containers, recovering field-by-field instead of failing the whole payload.
struct JSONishScanner {
    private let chars: [Character]
    private var index: Int = 0
    private let mode: JSONishParseMode

    private static let maxDepth = 24
    private static let maxMembers = 4096

    static func parse(_ text: String, mode: JSONishParseMode) -> JSONish? {
        var scanner = JSONishScanner(text: text, mode: mode)
        scanner.skipTrivia()
        guard let value = scanner.value(depth: 0) else { return nil }
        scanner.skipTrivia()
        if mode == .strict && !scanner.isAtEnd { return nil }
        return value
    }

    private init(text: String, mode: JSONishParseMode) {
        self.chars = Array(text)
        self.mode = mode
    }

    private var isAtEnd: Bool { index >= chars.count }

    private func peek(_ offset: Int = 0) -> Character? {
        let i = index + offset
        return i < chars.count ? chars[i] : nil
    }

    private mutating func advance() {
        if index < chars.count { index += 1 }
    }

    private mutating func skipTrivia() {
        while index < chars.count {
            let ch = chars[index]
            if ch.isWhitespace {
                index += 1
                continue
            }
            if mode == .lenient, ch == "/", let next = peek(1) {
                if next == "/" {
                    while index < chars.count && chars[index] != "\n" { index += 1 }
                    continue
                }
                if next == "*" {
                    index += 2
                    while index < chars.count {
                        if chars[index] == "*" && peek(1) == "/" {
                            index += 2
                            break
                        }
                        index += 1
                    }
                    continue
                }
            }
            break
        }
    }

    private mutating func value(depth: Int) -> JSONish? {
        guard depth < Self.maxDepth else { return nil }
        skipTrivia()
        guard let ch = peek() else { return nil }
        switch ch {
        case "{": return object(depth: depth)
        case "[": return array(depth: depth)
        case "\"": return string(quote: "\"").map(JSONish.string)
        case "'":
            guard mode == .lenient else { return nil }
            return string(quote: "'").map(JSONish.string)
        default:
            break
        }
        if let literal = literal() { return literal }
        if let n = number() { return .number(n) }
        if mode == .lenient, let word = bareWord() { return Self.interpret(bareWord: word) }
        return nil
    }

    private mutating func literal() -> JSONish? {
        let candidates: [(String, JSONish)] = [
            ("true", .bool(true)),
            ("false", .bool(false)),
            ("null", .null),
        ]
        for (word, value) in candidates where matchWord(word) {
            return value
        }
        return nil
    }

    private mutating func matchWord(_ word: String) -> Bool {
        let target = Array(word)
        guard index + target.count <= chars.count else { return false }
        for (offset, expected) in target.enumerated() {
            let actual = chars[index + offset]
            if mode == .strict {
                if actual != expected { return false }
            } else if actual.lowercased() != expected.lowercased() {
                return false
            }
        }
        if let after = peek(target.count), after.isLetter || after.isNumber || after == "_" {
            return false
        }
        index += target.count
        return true
    }

    private mutating func string(quote: Character) -> String? {
        guard peek() == quote else { return nil }
        advance()
        var out = ""
        while let ch = peek() {
            if ch == quote {
                advance()
                return out
            }
            if ch == "\\" {
                advance()
                guard let escape = peek() else {
                    return mode == .lenient ? out : nil
                }
                advance()
                switch escape {
                case "\"": out.append("\"")
                case "'": out.append("'")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    var hex = ""
                    for _ in 0..<4 {
                        guard let digit = peek(), digit.isHexDigit else { break }
                        hex.append(digit)
                        advance()
                    }
                    // Lone surrogate halves are dropped rather than failing the payload;
                    // metadata strings are UI labels, so a mangled label beats no shader.
                    if hex.count == 4, let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        out.unicodeScalars.append(scalar)
                    }
                default:
                    if mode == .strict { return nil }
                    out.append(escape)
                }
                continue
            }
            if mode == .strict, ch == "\n" { return nil }
            out.append(ch)
            advance()
        }
        return mode == .lenient ? out : nil
    }

    private mutating func number() -> Double? {
        let start = index
        var text = ""
        if let ch = peek(), ch == "-" || (ch == "+" && mode == .lenient) {
            text.append(ch)
            advance()
        }
        var digitCount = 0
        while let ch = peek(), ch.isASCII, ch.isNumber {
            text.append(ch)
            advance()
            digitCount += 1
        }
        if peek() == "." {
            text.append(".")
            advance()
            while let ch = peek(), ch.isASCII, ch.isNumber {
                text.append(ch)
                advance()
                digitCount += 1
            }
        }
        guard digitCount > 0 else {
            index = start
            return nil
        }
        if let ch = peek(), ch == "e" || ch == "E" {
            let save = index
            var exponent = String(ch)
            advance()
            if let sign = peek(), sign == "+" || sign == "-" {
                exponent.append(sign)
                advance()
            }
            var exponentDigits = 0
            while let ch = peek(), ch.isASCII, ch.isNumber {
                exponent.append(ch)
                advance()
                exponentDigits += 1
            }
            if exponentDigits == 0 {
                index = save
            } else {
                text += exponent
            }
        }
        guard let value = Double(text) else {
            index = start
            return nil
        }
        return value
    }

    private mutating func bareWord() -> String? {
        var out = ""
        while let ch = peek() {
            if ch.isWhitespace { break }
            if "{}[],:=\"'".contains(ch) { break }
            if ch == "/", let next = peek(1), next == "/" || next == "*" { break }
            out.append(ch)
            advance()
        }
        return out.isEmpty ? nil : out
    }

    private static func interpret(bareWord word: String) -> JSONish {
        switch word.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null", "nil", "undefined": return .null
        default: break
        }
        if let d = Double(word) { return .number(d) }
        return .string(word)
    }

    private mutating func object(depth: Int) -> JSONish? {
        guard peek() == "{" else { return nil }
        advance()
        var result = JSONishObject()
        var iterations = 0
        while true {
            iterations += 1
            guard iterations <= Self.maxMembers else {
                return mode == .lenient ? .object(result) : nil
            }
            skipTrivia()
            guard let ch = peek() else {
                return mode == .lenient ? .object(result) : nil
            }
            if ch == "}" {
                advance()
                return .object(result)
            }
            if ch == "," {
                advance()
                continue
            }

            var key: String?
            if ch == "\"" {
                key = string(quote: "\"")
            } else if ch == "'", mode == .lenient {
                key = string(quote: "'")
            } else if mode == .lenient {
                key = bareWord()
            }
            guard let name = key, !name.isEmpty else {
                if mode == .strict { return nil }
                guard recover(closing: "}") else { return .object(result) }
                continue
            }

            skipTrivia()
            if let separator = peek(), separator == ":" || (mode == .lenient && separator == "=") {
                advance()
            } else if mode == .strict {
                return nil
            }

            skipTrivia()
            guard let parsed = value(depth: depth + 1) else {
                if mode == .strict { return nil }
                guard recover(closing: "}") else { return .object(result) }
                continue
            }
            result.set(name, parsed)

            skipTrivia()
            guard let next = peek() else {
                return mode == .lenient ? .object(result) : nil
            }
            if next == "," {
                advance()
                continue
            }
            if next == "}" {
                advance()
                return .object(result)
            }
            if mode == .strict { return nil }
            // Lenient: a missing comma is tolerated; the loop re-reads a key.
        }
    }

    private mutating func array(depth: Int) -> JSONish? {
        guard peek() == "[" else { return nil }
        advance()
        var result: [JSONish] = []
        var iterations = 0
        while true {
            iterations += 1
            guard iterations <= Self.maxMembers else {
                return mode == .lenient ? .array(result) : nil
            }
            skipTrivia()
            guard let ch = peek() else {
                return mode == .lenient ? .array(result) : nil
            }
            if ch == "]" {
                advance()
                return .array(result)
            }
            if ch == "," {
                advance()
                continue
            }
            guard let parsed = value(depth: depth + 1) else {
                if mode == .strict { return nil }
                guard recover(closing: "]") else { return .array(result) }
                continue
            }
            result.append(parsed)

            skipTrivia()
            guard let next = peek() else {
                return mode == .lenient ? .array(result) : nil
            }
            if next == "," {
                advance()
                continue
            }
            if next == "]" {
                advance()
                return .array(result)
            }
            if mode == .strict { return nil }
        }
    }

    /// Skips forward to the next member boundary after an unparseable value.
    ///
    /// Returns `false` at end of input. The container's closing bracket is deliberately
    /// left unconsumed so the caller's loop terminates normally.
    private mutating func recover(closing: Character) -> Bool {
        var depth = 0
        while let ch = peek() {
            if ch == "\"" || ch == "'" {
                _ = string(quote: ch)
                continue
            }
            if ch == "{" || ch == "[" {
                depth += 1
                advance()
                continue
            }
            if ch == "}" || ch == "]" {
                if depth > 0 {
                    depth -= 1
                    advance()
                    continue
                }
                if ch == closing { return true }
                advance()
                continue
            }
            if ch == "," && depth == 0 {
                advance()
                return true
            }
            advance()
        }
        return false
    }
}
