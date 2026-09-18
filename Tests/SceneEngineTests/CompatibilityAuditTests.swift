import Diagnostics
import Foundation
import Testing
@testable import SceneEngine

@Suite("CompatibilityAudit")
struct CompatibilityAuditTests {

    private func entry(
        id: String,
        level: CompatibilityLevel = .degraded,
        findings: [CompatibilityFinding] = [],
        failure: String? = nil,
        layers: Int = 3,
        ownShaders: Int = 0,
        compiledEffects: Int = 0,
        approximatedEffects: Int = 0
    ) -> AuditEntry {
        AuditEntry(
            id: id, title: "Scene \(id)", type: "scene", level: level,
            findings: findings, layerCount: layers, particleEmitters: 0,
            scriptCount: 0, layersWithOwnShaders: ownShaders,
            compiledEffects: compiledEffects, approximatedEffects: approximatedEffects,
            loadSeconds: 0.01, failure: failure
        )
    }

    private func finding(_ feature: String, _ detail: String?) -> CompatibilityFinding {
        CompatibilityFinding(level: .degraded, feature: feature, detail: detail)
    }

    @Test("Counts each level")
    func countsLevels() {
        let summary = CompatibilityAudit().summarize([
            entry(id: "1", level: .supported),
            entry(id: "2", level: .supported),
            entry(id: "3", level: .degraded),
            entry(id: "4", level: .unsupported),
            entry(id: "5", failure: "corrupt"),
        ])
        #expect(summary.total == 5)
        #expect(summary.supported == 2)
        #expect(summary.degraded == 1)
        #expect(summary.unsupported == 1)
        #expect(summary.failed == 1)
        #expect(abs(summary.supportedShare - 0.4) < 0.001)
    }

    @Test("A failure is counted as failed, not by its level")
    func failureOutranksLevel() {
        // A wallpaper that could not be opened has no meaningful compatibility level, and
        // counting it in both buckets would make the numbers not add up.
        let summary = CompatibilityAudit().summarize([
            entry(id: "1", level: .unsupported, failure: "corrupt")
        ])
        #expect(summary.failed == 1)
        #expect(summary.unsupported == 0)
    }

    @Test("Ranks features by how many wallpapers they affect")
    func ranksByImpact() {
        let summary = CompatibilityAudit().summarize([
            entry(id: "1", findings: [finding("Texture", "a.tex is missing")]),
            entry(id: "2", findings: [finding("Texture", "b.tex is missing")]),
            entry(id: "3", findings: [finding("Texture", "c.tex is missing")]),
            entry(id: "4", findings: [finding("Effect", "Warp is not supported yet")]),
        ])
        #expect(summary.featureImpact.first?.feature == "Texture")
        #expect(summary.featureImpact.first?.wallpapers == 3)
        #expect(summary.featureImpact.last?.feature == "Effect")
    }

    @Test("A wallpaper with many findings of one feature counts once")
    func countsPerWallpaperNotPerFinding() {
        // Otherwise a single pathological scene with forty unsupported operators would dominate
        // the ranking and hide what actually affects the library.
        let noisy = entry(id: "1", findings: (0 ..< 40).map {
            finding("Particle operator", "op\($0) is not supported")
        })
        let summary = CompatibilityAudit().summarize([
            noisy,
            entry(id: "2", findings: [finding("Texture", "a.tex is missing")]),
            entry(id: "3", findings: [finding("Texture", "b.tex is missing")]),
        ])
        #expect(summary.featureImpact.first?.feature == "Texture")
        #expect(summary.featureImpact.first?.wallpapers == 2)
        #expect(
            summary.featureImpact.first { $0.feature == "Particle operator" }?.wallpapers == 1
        )
    }

    @Test("Ranking is stable when counts tie")
    func stableOrderingOnTies() {
        let summary = CompatibilityAudit().summarize([
            entry(id: "1", findings: [finding("Zeta", "x"), finding("Alpha", "y")]),
        ])
        // Alphabetical within a tie, so successive runs are diffable.
        #expect(summary.featureImpact.map(\.feature) == ["Alpha", "Zeta"])
    }

    // MARK: - Normalisation

    @Test("Collapses file paths so similar findings group")
    func normalizesPaths() {
        // Five different missing textures are one problem, not five rows.
        #expect(
            CompatibilityAudit.normalize("materials/snow_04.tex is missing")
                == CompatibilityAudit.normalize("materials/rain_11.tex is missing")
        )
        #expect(CompatibilityAudit.normalize("materials/a.tex is missing").contains("<file>"))
    }

    @Test("Collapses quoted object names")
    func normalizesQuotedNames() {
        #expect(
            CompatibilityAudit.normalize(#""Dust" is not drawn yet"#)
                == CompatibilityAudit.normalize(#""Snow" is not drawn yet"#)
        )
    }

    @Test("Leaves a detail with nothing variable in it alone")
    func leavesPlainDetailsIntact() {
        let detail = "turbulent velocity is approximated as linear"
        #expect(CompatibilityAudit.normalize(detail) == detail)
    }

    @Test("Different problems stay distinct after normalisation")
    func doesNotOverCollapse() {
        // Over-eager normalisation would merge unrelated issues and make the ranking useless.
        #expect(
            CompatibilityAudit.normalize("a.tex is missing")
                != CompatibilityAudit.normalize("a.tex could not be parsed")
        )
    }

    @Test("An empty library summarises without dividing by zero")
    func emptyLibrary() {
        let summary = CompatibilityAudit().summarize([])
        #expect(summary.total == 0)
        #expect(summary.supportedShare == 0)
        #expect(summary.featureImpact.isEmpty)
    }

    @Test("Fidelity is rolled up across the library")
    func rollsUpFidelity() {
        // The number that says whether transpiling shaders was worth it: how much of a real
        // library renders as its author wrote it rather than as an approximation.
        let summary = CompatibilityAudit().summarize([
            entry(id: "1", layers: 4, ownShaders: 4, compiledEffects: 2),
            entry(id: "2", layers: 6, ownShaders: 3, approximatedEffects: 1),
        ])

        #expect(summary.totalLayers == 10)
        #expect(summary.layersWithOwnShaders == 7)
        #expect(abs(summary.ownShaderShare - 0.7) < 0.001)
        #expect(summary.compiledEffects == 2)
        #expect(summary.approximatedEffects == 1)
    }

    @Test("An empty library reports no share rather than dividing by zero")
    func emptyLibraryShare() {
        #expect(CompatibilityAudit().summarize([]).ownShaderShare == 0)
    }
}
