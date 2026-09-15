import Foundation

/// How badly a shader problem affects the user, matching PLAN.md §5.6's three-state
/// compatibility report.
public enum ShaderDiagnosticSeverity: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Renders correctly; worth recording, not worth surfacing prominently.
    case info
    /// Renders, but with a named feature missing or a property binding lost.
    case degraded
    /// Cannot render this shader.
    case unsupported

    private var rank: Int {
        switch self {
        case .info: 0
        case .degraded: 1
        case .unsupported: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// What kind of problem was found. Kept separate from the message so the compatibility
/// report can group and count without string matching.
public enum ShaderDiagnosticKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// A construct this front-end does not recognize was left untouched on purpose.
    ///
    /// Emitted whenever we cannot tell a Wallpaper Engine extension apart from standard
    /// GLSL. Rewriting on a guess silently corrupts shaders, so we pass it through and
    /// say so.
    case unrecognizedConstruct
    /// A `// [COMBO]` annotation could not be parsed, or needed lenient recovery.
    case malformedComboMetadata
    /// A trailing `uniform` JSON annotation could not be parsed, or needed lenient recovery.
    case malformedUniformMetadata
    /// A combo value was supplied for a combo the shader never declares.
    case undeclaredCombo
    /// The same combo name is declared more than once.
    case duplicateCombo
    /// A combo macro we inject is also `#define`d by the shader itself.
    case comboMacroConflict
    /// No `#version` directive; the downstream compiler must supply a default.
    case missingVersionDirective
    /// Legacy `attribute` / `varying` storage qualifiers are in use.
    case legacyQualifiers
    /// An `#include` survived resolution (should not happen; indicates a parser gap).
    case unresolvedInclude
    /// A cache entry failed its integrity check and was discarded.
    case cacheEntryDiscarded
    /// The native GLSL→MSL backend is not vendored in this build.
    case backendUnavailable
}

/// One structured finding about a shader, feeding PLAN.md's per-wallpaper compatibility
/// report.
public struct ShaderDiagnostic: Sendable, Hashable, Codable {
    public var severity: ShaderDiagnosticSeverity
    public var kind: ShaderDiagnosticKind
    public var message: String

    /// The logical name of the shader being processed (the root, not the include).
    public var shaderName: String

    /// 1-based line number where known.
    ///
    /// For diagnostics returned by `ShaderPreprocessor` this is a line in the *original*
    /// file named by `originFile ?? shaderName`, not in the emitted GLSL.
    public var line: Int?

    /// Set when the offending line came from an `#include`d file rather than the root.
    public var originFile: String?

    public init(
        severity: ShaderDiagnosticSeverity,
        kind: ShaderDiagnosticKind,
        message: String,
        shaderName: String,
        line: Int? = nil,
        originFile: String? = nil
    ) {
        self.severity = severity
        self.kind = kind
        self.message = message
        self.shaderName = shaderName
        self.line = line
        self.originFile = originFile
    }
}

extension ShaderDiagnostic: CustomStringConvertible {
    public var description: String {
        let file = originFile ?? shaderName
        let where_ = line.map { "\(file):\($0)" } ?? file
        return "[\(severity.rawValue)] \(where_): \(message) (\(kind.rawValue))"
    }
}

public extension Array where Element == ShaderDiagnostic {
    /// The worst severity present, or `nil` when there are no diagnostics.
    var worstSeverity: ShaderDiagnosticSeverity? { map(\.severity).max() }

    func filter(kind: ShaderDiagnosticKind) -> [ShaderDiagnostic] {
        filter { $0.kind == kind }
    }

    func filter(severity: ShaderDiagnosticSeverity) -> [ShaderDiagnostic] {
        filter { $0.severity == severity }
    }
}
