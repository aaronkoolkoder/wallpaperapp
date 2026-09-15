import Foundation

/// How well a wallpaper actually renders.
///
/// This is the direct answer to the competitor's "handles most scenes correctly but not 100%".
/// The underlying reality is the same — some scenes use constructs we do not implement — but a
/// user who is told *what* is missing and *why* is in a completely different position from one
/// whose wallpaper silently looks wrong. Legible failure is the feature.
public enum CompatibilityLevel: Int, Comparable, Sendable, Codable {
    /// Renders as intended.
    case supported = 0
    /// Renders, but a named feature is missing or approximated.
    case degraded = 1
    /// Cannot be rendered at all.
    case unsupported = 2

    public static func < (lhs: CompatibilityLevel, rhs: CompatibilityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .supported: "Supported"
        case .degraded: "Partially supported"
        case .unsupported: "Not supported"
        }
    }
}

/// One specific thing we could not do, in language a user can act on.
public struct CompatibilityFinding: Sendable, Codable, Identifiable, Hashable {
    public var id: String { "\(level.rawValue):\(feature):\(detail ?? "")" }

    public let level: CompatibilityLevel
    /// Short feature name, e.g. "Audio reactivity", "Particle system".
    public let feature: String
    /// Optional specifics, e.g. the shader or object that failed.
    public let detail: String?
    /// Where it came from, for debugging. Not shown in the main UI.
    public let source: String?

    public init(level: CompatibilityLevel, feature: String, detail: String? = nil, source: String? = nil) {
        self.level = level
        self.feature = feature
        self.detail = detail
        self.source = source
    }
}

/// The full verdict for one wallpaper.
public struct CompatibilityReport: Sendable, Codable {
    public let wallpaperID: String
    public private(set) var findings: [CompatibilityFinding]
    public var generatedAt: Date

    /// The report's level is the worst of its findings — one unsupported object makes the whole
    /// wallpaper unsupported, because that is what the user will actually see.
    public var level: CompatibilityLevel {
        findings.map(\.level).max() ?? .supported
    }

    public var isFullySupported: Bool { level == .supported }

    public init(wallpaperID: String, findings: [CompatibilityFinding] = [], generatedAt: Date = .now) {
        self.wallpaperID = wallpaperID
        self.findings = findings
        self.generatedAt = generatedAt
    }

    public mutating func add(_ finding: CompatibilityFinding) {
        // Deduplicate: a shader construct we do not support will typically be hit once per
        // object, and a report listing the same line forty times is noise, not information.
        guard !findings.contains(finding) else { return }
        findings.append(finding)
    }

    public mutating func add(
        _ level: CompatibilityLevel, feature: String, detail: String? = nil, source: String? = nil
    ) {
        add(CompatibilityFinding(level: level, feature: feature, detail: detail, source: source))
    }

    /// A one-line summary for the library grid badge.
    public var summary: String {
        switch level {
        case .supported:
            return "Renders correctly"
        case .degraded:
            let count = findings.filter { $0.level == .degraded }.count
            return count == 1
                ? "1 feature unavailable"
                : "\(count) features unavailable"
        case .unsupported:
            guard let blocker = findings.first(where: { $0.level == .unsupported }) else {
                return "Cannot be rendered"
            }
            if let detail = blocker.detail { return "\(blocker.feature): \(detail)" }
            return blocker.feature
        }
    }
}
