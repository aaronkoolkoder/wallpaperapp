import Foundation

/// Which GLSL pipeline stage a piece of Wallpaper Engine shader source belongs to.
///
/// Wallpaper Engine ships shader programs as a `.vert` / `.frag` pair sharing a
/// basename; materials reference the pair by that basename. We only ever need the
/// two rasterization stages — the format has no compute or geometry shaders.
public enum ShaderStage: String, Sendable, Hashable, Codable, CaseIterable {
    case vertex
    case fragment

    /// The on-disk extension Wallpaper Engine uses for this stage, with no leading dot.
    public var fileExtension: String {
        switch self {
        case .vertex: "vert"
        case .fragment: "frag"
        }
    }

    /// Maps a file extension onto a stage.
    ///
    /// - Note: `TODO(verify):` only `.vert` / `.frag` have been confirmed against real
    ///   Wallpaper Engine content. The `.vs` / `.fs` spellings are accepted defensively
    ///   because they are common in GLSL toolchains, not because they were observed.
    public init?(fileExtension: String) {
        let normalized = fileExtension
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        switch normalized {
        case "vert", "vs", "vertex": self = .vertex
        case "frag", "fs", "fragment", "pixel": self = .fragment
        default: return nil
        }
    }
}

/// A single unit of Wallpaper Engine shader text, before any preprocessing.
///
/// `text` is the raw contents as shipped: GLSL with Wallpaper Engine's own
/// preprocessor layer on top (`#include`, `// [COMBO]` variant declarations, and
/// trailing JSON annotations on `uniform` declarations). Nothing here is normalized;
/// `ShaderPreprocessor` is what turns this into GLSL a standard compiler will accept.
public struct ShaderSource: Sendable, Hashable {
    /// Logical name used in diagnostics and as the root of the include stack,
    /// e.g. `"effects/bloom.frag"`.
    public var name: String

    /// The pipeline stage this source compiles into.
    public var stage: ShaderStage

    /// Raw, unmodified shader text.
    public var text: String

    public init(name: String, stage: ShaderStage, text: String) {
        self.name = name
        self.stage = stage
        self.text = text
    }

    /// Builds a source, inferring the stage from the name's extension.
    ///
    /// Returns `nil` when the extension is not one this module recognizes, rather than
    /// guessing — picking the wrong stage produces a shader that compiles and renders
    /// nothing, which is much harder to diagnose than an outright failure.
    public init?(name: String, text: String) {
        let ext = (name as NSString).pathExtension
        guard let stage = ShaderStage(fileExtension: ext) else { return nil }
        self.init(name: name, stage: stage, text: text)
    }
}

/// A 1-based position in an original (pre-include-expansion) shader file.
public struct SourceLocation: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The file the line came from — either the root shader's name or an include's name.
    public var file: String

    /// 1-based line number within `file`.
    public var line: Int

    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }

    public var description: String { "\(file):\(line)" }
}

/// Line splitting/joining that round-trips exactly, so line counts stay meaningful.
///
/// Wallpaper Engine content originates on Windows, so CRLF and lone CR both occur.
/// Normalizing once here keeps every downstream line index consistent.
enum SourceText {
    static func lines(of text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    static func join(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    /// True when `text` begins with `keyword` followed by a non-identifier character.
    ///
    /// Prevents `uniformity` from matching `uniform`.
    static func startsWithKeyword(_ text: String, _ keyword: String) -> Bool {
        guard text.hasPrefix(keyword) else { return false }
        guard let next = text.dropFirst(keyword.count).first else { return true }
        return !(next.isLetter || next.isNumber || next == "_")
    }

    /// True when `text` is a legal GLSL identifier.
    ///
    /// Used as a gate before anything reaches a generated `#define`, so that malformed
    /// metadata cannot inject arbitrary text into the emitted GLSL.
    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        guard first.isASCII else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var out = text
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return out
    }
}

/// Splits GLSL lines into code and trailing `//` comment, tracking `/* */` state across
/// lines.
///
/// This matters because every piece of Wallpaper Engine metadata lives in a `//`
/// comment. Without block-comment tracking, a commented-out `// [COMBO]` block would be
/// parsed as a live declaration.
struct CommentSplitter {
    struct Scan: Sendable, Hashable {
        /// The code portion of the line, with block-comment spans replaced by a space.
        var code: String
        /// Text after the `//`, if any (the `//` itself is not included).
        var comment: String?
        /// Character offset of the `//` within the original line, if any.
        var commentStart: Int?
    }

    private var inBlockComment = false

    init() {}

    mutating func scan(_ line: String) -> Scan {
        let chars = Array(line)
        var code = ""
        var i = 0
        while i < chars.count {
            if inBlockComment {
                if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    inBlockComment = false
                    code.append(" ")
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
            if chars[i] == "/", i + 1 < chars.count {
                if chars[i + 1] == "/" {
                    return Scan(code: code, comment: String(chars[(i + 2)...]), commentStart: i)
                }
                if chars[i + 1] == "*" {
                    inBlockComment = true
                    code.append(" ")
                    i += 2
                    continue
                }
            }
            code.append(chars[i])
            i += 1
        }
        return Scan(code: code, comment: nil, commentStart: nil)
    }
}
