import Foundation
import Testing
@testable import ShaderTranspiler

/// A backend that counts calls and can be told to fail, so the tests can tell a cache hit from
/// a recompile without needing the vendored toolchain.
private final class CountingBackend: TranspilerBackend, @unchecked Sendable {
    private(set) var compileCount = 0
    var msl: String
    var reflection: ShaderReflection

    init(msl: String = "// translated\nfragment void main0() {}", reflection: ShaderReflection = ShaderReflection(entryPoint: "main0")) {
        self.msl = msl
        self.reflection = reflection
    }

    func compile(glsl: String, stage: ShaderStage) throws -> TranspiledShader {
        // The canary is how the cache fingerprints the toolchain, so every cache computes it
        // once whether or not the shader itself hits. Counting it here would make a hit look
        // like a miss.
        if glsl == ShaderCache.canary {
            return TranspiledShader(msl: "// canary", reflection: reflection)
        }
        compileCount += 1
        return TranspiledShader(msl: msl, reflection: reflection)
    }
}

@Suite("ShaderCache")
struct ShaderCacheTests {

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DioramaShaderCacheTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func shader(_ text: String = "#version 450\nvoid main() {}\n", name: String = "test.frag") throws -> PreprocessedShader {
        try ShaderPreprocessor().preprocess(
            ShaderSource(name: name, stage: .fragment, text: text),
            provider: InMemoryShaderFileProvider([:])
        )
    }

    @Test("A second lookup does not recompile")
    func memoryHit() throws {
        let backend = CountingBackend()
        let cache = ShaderCache(directory: nil)
        let source = try shader()
        var diagnostics: [ShaderDiagnostic] = []

        _ = try cache.shader(for: source, backend: backend, diagnostics: &diagnostics)
        let before = backend.compileCount
        _ = try cache.shader(for: source, backend: backend, diagnostics: &diagnostics)

        #expect(backend.compileCount == before)
    }

    @Test("A translation survives into a new cache over the same directory")
    func diskRoundTrip() throws {
        // This is the point of the cache: PLAN.md §5.4 pays for translation once at import, and
        // without persistence "once" would mean once per launch.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let backend = CountingBackend()
        let source = try shader()
        var diagnostics: [ShaderDiagnostic] = []

        let first = try ShaderCache(directory: directory)
            .shader(for: source, backend: backend, diagnostics: &diagnostics)
        let countAfterFirst = backend.compileCount

        let second = try ShaderCache(directory: directory)
            .shader(for: source, backend: backend, diagnostics: &diagnostics)

        #expect(first == second)
        #expect(backend.compileCount == countAfterFirst)
    }

    @Test("Different shaders do not share an entry")
    func distinctShaders() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let backend = CountingBackend()
        let cache = ShaderCache(directory: directory)
        var diagnostics: [ShaderDiagnostic] = []

        _ = try cache.shader(for: try shader(), backend: backend, diagnostics: &diagnostics)
        let before = backend.compileCount
        _ = try cache.shader(
            for: try shader("#version 450\nvoid main() { float x = 1.0; }\n"),
            backend: backend, diagnostics: &diagnostics
        )
        #expect(backend.compileCount > before)
    }

    @Test("A corrupt entry is discarded and reported, not served")
    func discardsCorruptEntries() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let backend = CountingBackend()
        let cache = ShaderCache(directory: directory)
        let source = try shader()
        var diagnostics: [ShaderDiagnostic] = []
        _ = try cache.shader(for: source, backend: backend, diagnostics: &diagnostics)

        // Simulate a truncated write.
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "json" } ?? []
        #expect(!files.isEmpty)
        for file in files { try Data("{ not json".utf8).write(to: file) }

        cache.flushMemory()
        let recovered = try cache.shader(for: source, backend: backend, diagnostics: &diagnostics)

        #expect(recovered.msl == backend.msl)
        #expect(diagnostics.contains { $0.kind == .cacheEntryDiscarded })
    }

    @Test("An entry stored for a different shader is refused")
    func refusesMismatchedEntry() throws {
        // File names are hashes, so this only happens after tampering or a collision — but
        // serving the wrong shader would be far harder to diagnose than recompiling.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try shader()
        let entry = ShaderCacheEntry(
            sourceHash: "not-the-right-hash",
            stage: .fragment,
            shader: TranspiledShader(msl: "// wrong", reflection: ShaderReflection(entryPoint: "main0"))
        )
        let url = directory.appendingPathComponent("entry.json")
        try JSONEncoder().encode(entry).write(to: url)

        let cache = ShaderCache(directory: directory)
        let outcome = cache.readEntry(at: url, expecting: source)

        guard case .corrupt = outcome else {
            Issue.record("expected the mismatched entry to be refused, got \(outcome)")
            return
        }
    }

    @Test("Stored entries stay inside the byte budget")
    func evictsPastBudget() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Large enough that a couple of entries blow the budget.
        let backend = CountingBackend(msl: String(repeating: "// padding\n", count: 400))
        let cache = ShaderCache(directory: directory, byteBudget: 6 * 1024)
        var diagnostics: [ShaderDiagnostic] = []

        for index in 0 ..< 8 {
            let source = try shader("#version 450\nvoid main() { float x = \(index).0; }\n")
            _ = try cache.shader(for: source, backend: backend, diagnostics: &diagnostics)
        }

        let total = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { $0 as? URL }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }) ?? 0

        // Eviction runs after each write, so the directory can hold one entry's overshoot.
        #expect(total <= 6 * 1024 + backend.msl.utf8.count * 2)
    }

    @Test("A different toolchain does not reuse the old translations")
    func identityChangesWithToolchain() throws {
        // Cached MSL is only valid for the toolchain that produced it, and re-running the
        // vendor script can change either half of it. The identity is derived from what the
        // backend actually emits rather than from a version constant someone has to remember
        // to bump.
        let first = CountingBackend()
        first.msl = "// build one"
        let second = CountingBackend()
        second.reflection = ShaderReflection(entryPoint: "main1")
        second.msl = "// build two"

        let cache = ShaderCache(directory: temporaryDirectory())
        let other = ShaderCache(directory: temporaryDirectory())

        // The canary translates differently under each backend, so the identities differ.
        let firstIdentity = cache.identity(of: first)
        let secondIdentity = other.identity(of: SwappedCanaryBackend())

        #expect(firstIdentity != nil)
        #expect(firstIdentity != secondIdentity)
    }

    @Test("A backend that cannot translate leaves nothing behind")
    func unavailableBackendStoresNothing() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ShaderCache(directory: directory)
        #expect(cache.identity(of: UnavailableTranspilerBackend()) == nil)

        var diagnostics: [ShaderDiagnostic] = []
        #expect(throws: (any Error).self) {
            try cache.shader(
                for: try shader(), backend: UnavailableTranspilerBackend(), diagnostics: &diagnostics
            )
        }
    }
}

/// Emits different MSL for the canary, standing in for a different toolchain build.
private struct SwappedCanaryBackend: TranspilerBackend {
    func compile(glsl: String, stage: ShaderStage) throws -> TranspiledShader {
        TranspiledShader(
            msl: glsl == ShaderCache.canary ? "// canary from another build" : "// translated",
            reflection: ShaderReflection(entryPoint: "main0")
        )
    }
}

@Suite("ShaderCache under concurrency")
struct ShaderCacheConcurrencyTests {

    /// Counts compiles across threads, so the test can tell a hit from a recompile safely.
    private final class ThreadSafeBackend: TranspilerBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var compileCount: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        func compile(glsl: String, stage: ShaderStage) throws -> TranspiledShader {
            if glsl == ShaderCache.canary {
                return TranspiledShader(msl: "// canary", reflection: ShaderReflection(entryPoint: "main0"))
            }
            lock.lock()
            count += 1
            lock.unlock()
            // Long enough that concurrent callers genuinely overlap rather than serialising by
            // luck of scheduling.
            Thread.sleep(forTimeInterval: 0.002)
            return TranspiledShader(
                msl: "// \(glsl.count)", reflection: ShaderReflection(entryPoint: "main0")
            )
        }
    }

    private func shader(_ index: Int) throws -> PreprocessedShader {
        try ShaderPreprocessor().preprocess(
            ShaderSource(
                name: "s\(index).frag", stage: .fragment,
                text: "void main() { float x = \(index).0; }"
            ),
            provider: InMemoryShaderFileProvider([:])
        )
    }

    @Test("Concurrent lookups of the same shader do not corrupt the cache")
    func concurrentSameShader() throws {
        // Wallpapers import on several queues; a torn dictionary here would crash rather than
        // misrender, which is the worst way for a cache to fail.
        let backend = ThreadSafeBackend()
        let cache = ShaderCache(directory: nil)
        let source = try shader(0)

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            var diagnostics: [ShaderDiagnostic] = []
            _ = try? cache.shader(for: source, backend: backend, diagnostics: &diagnostics)
        }

        // Two callers can race past the lock and both compile; what must not happen is 64 of
        // them, or a crash.
        #expect(backend.compileCount < 64)
        #expect(backend.compileCount >= 1)
    }

    @Test("Concurrent lookups of different shaders all return their own translation")
    func concurrentDistinctShaders() throws {
        let backend = ThreadSafeBackend()
        let cache = ShaderCache(directory: nil)
        let sources = try (0 ..< 32).map { try shader($0) }
        let results = NSMutableDictionary()
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: sources.count) { index in
            var diagnostics: [ShaderDiagnostic] = []
            guard let translated = try? cache.shader(
                for: sources[index], backend: backend, diagnostics: &diagnostics
            ) else { return }
            lock.lock()
            results[index] = translated.msl
            lock.unlock()
        }

        #expect(results.count == sources.count)
        // Each shader's MSL is derived from its own length, so a mix-up would show up here.
        for index in 0 ..< sources.count {
            #expect(results[index] as? String == "// \(sources[index].glsl.count)")
        }
    }

    @Test("Concurrent identity computation settles on one answer")
    func concurrentIdentity() throws {
        // Computed outside the lock on purpose, so several callers can race to produce it. They
        // must all end up agreeing, or entries written by one would be invisible to another.
        let backend = ThreadSafeBackend()
        let cache = ShaderCache(directory: nil)
        let answers = NSMutableSet()
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let identity = cache.identity(of: backend)
            lock.lock()
            answers.add(identity ?? "nil")
            lock.unlock()
        }

        #expect(answers.count == 1)
    }
}
