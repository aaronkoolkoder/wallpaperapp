import Foundation
import os

/// A translated shader as it is stored, with enough context to validate it on the way back in.
struct ShaderCacheEntry: Codable, Sendable {
    /// Content hash of the GLSL this was translated from. Checked on read so a hash collision
    /// in a file name cannot serve the wrong shader.
    var sourceHash: String
    var stage: ShaderStage
    var shader: TranspiledShader
}

/// Caches GLSL-to-MSL translation across launches.
///
/// PLAN.md §5.4 pays for translation once at import rather than per frame; this is what makes
/// "once" mean once ever rather than once per launch. A scene with twenty materials and a few
/// combo variants is a few hundred translations, and each is tens of milliseconds.
///
/// Invalidation is the part worth being careful about. Cached MSL is only valid for the exact
/// toolchain that produced it, and re-running the vendor script can change either glslang or
/// SPIRV-Cross. Rather than hoping a version constant is remembered and bumped, the cache
/// derives its own identity by translating a fixed canary shader and hashing the result: any
/// behavioural change in either tool changes the hash, and stale entries are then unreachable
/// because they live under the old identity's directory.
public final class ShaderCache: Sendable {
    /// Bumped when the *layout* of a stored entry changes, which no canary would notice.
    static let formatVersion = 1

    /// A shader chosen to exercise the parts of both tools most likely to change: a uniform
    /// block with std140 padding, a combined image sampler, and a varying.
    static let canary = """
    #version 450
    layout(std140) uniform DioramaCanary { vec4 tint; float weight; vec3 axis; };
    layout(binding = 0) uniform sampler2D source;
    layout(location = 0) in vec2 uv;
    layout(location = 0) out vec4 color;
    void main() { color = texture(source, uv) * tint * weight * vec4(axis, 1.0); }

    """

    /// Total budget for stored entries. Translated MSL runs a few kilobytes each, so this holds
    /// a large library comfortably; the bound exists so it cannot grow without end.
    public static let defaultByteBudget: UInt64 = 32 * 1024 * 1024

    private struct State {
        var memory: [String: TranspiledShader] = [:]
        var identity: String?
        var identityAttempted = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let root: URL?
    private let byteBudget: UInt64
    /// `FileManager.default` is documented as safe to use from multiple threads; a stored
    /// instance would not be, and there is no reason to hold one.
    private var fileManager: FileManager { .default }
    private let log = Logger(subsystem: "app.diorama", category: "shadercache")

    /// - Parameter directory: where entries are stored, or `nil` for memory only. Memory-only
    ///   is what tests use, and what a sandboxed build falls back to if the directory cannot
    ///   be created.
    public init(directory: URL? = ShaderCache.defaultDirectory, byteBudget: UInt64 = ShaderCache.defaultByteBudget) {
        self.root = directory
        self.byteBudget = byteBudget
    }

    /// Kept beside the other derived data in Application Support rather than in the wallpaper
    /// folder, which may be read-only or on a removable volume.
    public static var defaultDirectory: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return support.appendingPathComponent("Diorama/ShaderCache", isDirectory: true)
    }

    // MARK: - Lookup

    /// Returns the translated shader, translating and storing it only if it is not already held.
    ///
    /// Diagnostics are appended rather than thrown for cache problems: a cache that cannot be
    /// read is a slow import, not a broken wallpaper.
    public func shader(
        for preprocessed: PreprocessedShader,
        backend: any TranspilerBackend,
        diagnostics: inout [ShaderDiagnostic]
    ) throws -> TranspiledShader {
        let key = Self.key(sourceHash: preprocessed.sourceHash, stage: preprocessed.stage)

        if let hit = state.withLock({ $0.memory[key] }) { return hit }

        if let url = entryURL(for: key, backend: backend) {
            switch readEntry(at: url, expecting: preprocessed) {
            case .hit(let shader):
                state.withLock { $0.memory[key] = shader }
                return shader
            case .miss:
                break
            case .corrupt(let reason):
                diagnostics.append(ShaderDiagnostic(
                    severity: .info,
                    kind: .cacheEntryDiscarded,
                    message: "A cached translation was discarded and rebuilt: \(reason).",
                    shaderName: preprocessed.name
                ))
                try? fileManager.removeItem(at: url)
            }
        }

        let translated = try backend.compile(glsl: preprocessed.glsl, stage: preprocessed.stage)
        state.withLock { $0.memory[key] = translated }
        store(translated, for: key, sourceHash: preprocessed.sourceHash, stage: preprocessed.stage, backend: backend)
        return translated
    }

    /// Drops everything held in memory. The stored entries are left alone.
    public func flushMemory() {
        state.withLock { $0.memory.removeAll() }
    }

    /// Removes every stored entry for every toolchain identity.
    public func removeAll() {
        flushMemory()
        guard let root else { return }
        try? fileManager.removeItem(at: root)
    }

    // MARK: - Identity

    /// The toolchain fingerprint, computed once per cache.
    ///
    /// `nil` when the backend cannot translate at all, in which case nothing is stored.
    func identity(of backend: any TranspilerBackend) -> String? {
        let known = state.withLock { ($0.identityAttempted, $0.identity) }
        if known.0 { return known.1 }

        // Deliberately computed outside the lock: translating the canary calls into the
        // backend, and holding a lock across that would serialise every concurrent import
        // behind it.
        let computed: String?
        do {
            let translated = try backend.compile(glsl: Self.canary, stage: .fragment)
            let fingerprint = ShaderHashing.sha256Hex(translated.msl)
            computed = "v\(Self.formatVersion)-\(fingerprint.prefix(16))"
        } catch {
            computed = nil
        }

        state.withLock {
            $0.identityAttempted = true
            $0.identity = computed
        }
        return computed
    }

    // MARK: - Storage

    static func key(sourceHash: String, stage: ShaderStage) -> String {
        "\(sourceHash)-\(stage.rawValue)"
    }

    private func entryURL(for key: String, backend: any TranspilerBackend) -> URL? {
        guard let root, let identity = identity(of: backend) else { return nil }
        return root
            .appendingPathComponent(identity, isDirectory: true)
            .appendingPathComponent("\(key).json", isDirectory: false)
    }

    enum ReadOutcome {
        case hit(TranspiledShader)
        case miss
        case corrupt(String)
    }

    func readEntry(at url: URL, expecting preprocessed: PreprocessedShader) -> ReadOutcome {
        guard let data = try? Data(contentsOf: url) else { return .miss }
        guard let entry = try? JSONDecoder().decode(ShaderCacheEntry.self, from: data) else {
            return .corrupt("it could not be read")
        }
        guard entry.sourceHash == preprocessed.sourceHash, entry.stage == preprocessed.stage else {
            return .corrupt("it was stored for a different shader")
        }
        guard !entry.shader.msl.isEmpty else {
            return .corrupt("it held no translated source")
        }
        // Reading counts as a use, so eviction keeps what is actually being rendered rather
        // than only what was imported most recently.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return .hit(entry.shader)
    }

    private func store(
        _ shader: TranspiledShader,
        for key: String,
        sourceHash: String,
        stage: ShaderStage,
        backend: any TranspilerBackend
    ) {
        guard let url = entryURL(for: key, backend: backend) else { return }
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let entry = ShaderCacheEntry(sourceHash: sourceHash, stage: stage, shader: shader)
            let data = try JSONEncoder().encode(entry)
            // Atomic so a crash mid-write cannot leave a truncated entry that reads as corrupt
            // on every subsequent launch.
            try data.write(to: url, options: .atomic)
        } catch {
            log.debug("could not store a translated shader: \(error.localizedDescription, privacy: .public)")
            return
        }
        evictIfNeeded(in: directory)
    }

    /// Trims the oldest entries until the directory is back inside the budget.
    func evictIfNeeded(in directory: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        ) else { return }

        var entries: [(url: URL, size: UInt64, modified: Date)] = []
        var total: UInt64 = 0
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let size = UInt64(values.fileSize ?? 0)
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
            total += size
        }

        guard total > byteBudget else { return }

        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            guard total > byteBudget else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= min(total, entry.size)
        }
    }
}
