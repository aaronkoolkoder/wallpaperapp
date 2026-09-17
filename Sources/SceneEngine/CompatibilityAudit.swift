import Diagnostics
import Foundation
import Metal
import WEFormat
import os

/// Result of auditing one wallpaper.
public struct AuditEntry: Sendable {
    public let id: String
    public let title: String
    public let type: String
    public let level: CompatibilityLevel
    public let findings: [CompatibilityFinding]
    public let layerCount: Int
    public let particleEmitters: Int
    public let scriptCount: Int
    public let loadSeconds: Double
    /// Set when the wallpaper could not be opened at all.
    public let failure: String?

    public var isRenderable: Bool { failure == nil && layerCount > 0 }
}

/// Audits a whole library and aggregates what is missing.
///
/// The per-wallpaper report answers "why does this one look wrong". This answers the more useful
/// question: across everything the user actually owns, which unimplemented features account for
/// the most broken wallpapers. That turns a backlog ordered by guesswork into one ordered by how
/// often it bites, which is the only way to prioritise a compatibility effort sensibly.
public struct CompatibilityAudit: Sendable {
    public struct Summary: Sendable {
        public var total = 0
        public var supported = 0
        public var degraded = 0
        public var unsupported = 0
        public var failed = 0
        /// Feature name to number of wallpapers affected, most common first.
        public var featureImpact: [(feature: String, wallpapers: Int)] = []
        /// Specific details under each feature, so "Effect" can be broken down into which ones.
        public var detailImpact: [(detail: String, wallpapers: Int)] = []
        public var totalSeconds: Double = 0

        /// Share of the library that renders with nothing missing.
        public var supportedShare: Double {
            total > 0 ? Double(supported) / Double(total) : 0
        }
    }

    private let log = Logger(subsystem: "app.diorama", category: "audit")

    public init() {}

    /// Audit one wallpaper directory.
    public func audit(
        id: String,
        title: String,
        type: String,
        directory: URL,
        packageURL: URL?,
        device: any MTLDevice
    ) -> AuditEntry {
        let started = Date()
        do {
            let scene = try SceneRenderer.loadScene(
                directory: directory, packageURL: packageURL, wallpaperID: id, device: device
            )
            return AuditEntry(
                id: id, title: title, type: type,
                level: scene.report.level,
                findings: scene.report.findings,
                layerCount: scene.layers.count,
                particleEmitters: scene.particles.count,
                scriptCount: scene.scriptBindings.count,
                loadSeconds: Date().timeIntervalSince(started),
                failure: nil
            )
        } catch {
            return AuditEntry(
                id: id, title: title, type: type,
                level: .unsupported, findings: [], layerCount: 0,
                particleEmitters: 0, scriptCount: 0,
                loadSeconds: Date().timeIntervalSince(started),
                failure: error.localizedDescription
            )
        }
    }

    /// Roll a set of entries up into a library-wide picture.
    public func summarize(_ entries: [AuditEntry]) -> Summary {
        var summary = Summary()
        summary.total = entries.count
        summary.totalSeconds = entries.reduce(0) { $0 + $1.loadSeconds }

        // Counted per wallpaper, not per finding: a scene with forty unsupported particle
        // operators is one wallpaper's worth of pain, and counting occurrences would let a
        // single pathological file dominate the ranking.
        var featureCounts: [String: Int] = [:]
        var detailCounts: [String: Int] = [:]

        for entry in entries {
            if entry.failure != nil {
                summary.failed += 1
            } else {
                switch entry.level {
                case .supported: summary.supported += 1
                case .degraded: summary.degraded += 1
                case .unsupported: summary.unsupported += 1
                }
            }

            for feature in Set(entry.findings.map(\.feature)) {
                featureCounts[feature, default: 0] += 1
            }
            for detail in Set(entry.findings.compactMap { finding -> String? in
                guard let detail = finding.detail else { return nil }
                return "\(finding.feature): \(Self.normalize(detail))"
            }) {
                detailCounts[detail, default: 0] += 1
            }
        }

        summary.featureImpact = featureCounts
            .map { (feature: $0.key, wallpapers: $0.value) }
            .sorted { $0.wallpapers > $1.wallpapers || ($0.wallpapers == $1.wallpapers && $0.feature < $1.feature) }
        summary.detailImpact = detailCounts
            .map { (detail: $0.key, wallpapers: $0.value) }
            .sorted { $0.wallpapers > $1.wallpapers || ($0.wallpapers == $1.wallpapers && $0.detail < $1.detail) }

        return summary
    }

    /// Collapse the variable part of a detail so similar findings group together.
    ///
    /// "materials/snow_04.tex is missing" and "materials/rain_11.tex is missing" are the same
    /// problem; left verbatim they would each occupy their own row and hide the fact that
    /// missing textures are one issue affecting many wallpapers.
    static func normalize(_ detail: String) -> String {
        var result = detail

        // Replace anything that looks like a path with a placeholder.
        if let regex = try? NSRegularExpression(pattern: #"[\w/\\.-]+\.(tex|json|pkg|frag|vert)"#) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "<file>"
            )
        }
        // And quoted object names.
        if let regex = try? NSRegularExpression(pattern: #""[^"]*""#) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "<name>"
            )
        }
        return result
    }
}
