import CoreGraphics
import Foundation
import ImageIO
import simd
import LibraryKit
import MetalRenderer
import Metal
import SceneEngine
import ShaderTranspiler
import UniformTypeIdentifiers
import WEFormat

/// Rewrites `ERROR: 0:37:` in a backend message to the file and line the author wrote.
func remapDiagnosticLines(_ detail: String, in shader: PreprocessedShader) -> String {
    let pattern = /(\d+):(\d+):/
    return detail.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        guard let match = line.firstMatch(of: pattern),
              let emitted = Int(match.2),
              let origin = shader.origin(ofEmittedLine: emitted)
        else { return String(line) }
        return String(line.replacing(pattern, with: "\(origin.file):\(origin.line):"))
    }.joined(separator: "\n")
}

// A developer CLI for inspecting Wallpaper Engine content without launching the app.
//
// Worth its keep during every later milestone: when a scene renders wrong, the first question is
// always whether the format layer read it correctly, and answering that from inside a running
// wallpaper is miserable.

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    wetool — inspect Wallpaper Engine content

    USAGE
      wetool scan <library-dir>          Index a wallpaper library and summarise it
      wetool pkg list <scene.pkg>        List the entries in a package
      wetool pkg cat <scene.pkg> <path>  Print one entry to stdout
      wetool pkg extract <scene.pkg> <out-dir>
      wetool tex info <file.tex>         Describe a texture
      wetool manifest <project.json>     Parse and dump a manifest
      wetool shader <file.frag|.vert>    Translate a shader to Metal and print it
      wetool report <library-dir> [--json <out.json>]
                                         Audit a whole library: what renders,
                                         what does not, and which missing
                                         features affect the most wallpapers
      wetool library [domain]            Report where the imported library folder
                                         is and whether it can still be reached
      wetool scene info <wallpaper-dir>  Describe a scene's layers
      wetool scene render <wallpaper-dir> <out.png> [WxH] [px,py]
                                         Render one frame offscreen; px,py is a
                                         normalised pointer in [-1,1] for parallax
    """)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileManager.default.fileExists(atPath: "/dev/stderr")
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func byteCount(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

guard let command = arguments.first else { usage() }

switch command {

case "scan":
    guard arguments.count >= 2 else { usage() }
    let root = URL(fileURLWithPath: arguments[1])
    let result = LibraryScanner().scan(root: root)

    print("scanned \(result.scannedDirectories) director\(result.scannedDirectories == 1 ? "y" : "ies") in \(String(format: "%.3f", result.duration))s")
    print("indexed \(result.items.count), playable \(result.playableCount)")

    var byType: [String: Int] = [:]
    for item in result.items { byType[item.type.rawValue, default: 0] += 1 }
    for (type, count) in byType.sorted(by: { $0.key < $1.key }) {
        print("  \(type): \(count)")
    }

    let unplayable = result.items.filter { !$0.isPlayable }
    if !unplayable.isEmpty {
        print("\nunplayable (\(unplayable.count)):")
        for item in unplayable.prefix(20) {
            print("  \(item.id)  \(item.title) — \(item.unplayableReason ?? "?")")
        }
    }
    if !result.failures.isEmpty {
        print("\nfailed to index (\(result.failures.count)):")
        for failure in result.failures.prefix(20) {
            print("  \(failure.directory) — \(failure.reason)")
        }
    }

case "pkg":
    guard arguments.count >= 3 else { usage() }
    let subcommand = arguments[1]
    let archive: PKGArchive
    do {
        archive = try PKGArchive(contentsOf: URL(fileURLWithPath: arguments[2]))
    } catch {
        fail("\(error)")
    }

    switch subcommand {
    case "list":
        print("\(archive.version) — \(archive.entries.count) entr\(archive.entries.count == 1 ? "y" : "ies")")
        for entry in archive.entries.sorted(by: { $0.path < $1.path }) {
            // Not String(format:) with %s — that expects a C string, and handing it a Swift
            // String silently prints nothing.
            let size = byteCount(entry.size)
            let padding = String(repeating: " ", count: max(0, 10 - size.count))
            print("  \(padding)\(size)  \(entry.path)")
        }
    case "cat":
        guard arguments.count >= 4 else { usage() }
        do {
            FileHandle.standardOutput.write(try archive.data(for: arguments[3]))
        } catch { fail("\(error)") }
    case "extract":
        guard arguments.count >= 4 else { usage() }
        let outputRoot = URL(fileURLWithPath: arguments[3])
        var written = 0
        for entry in archive.entries {
            let destination = outputRoot.appendingPathComponent(entry.path)
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try archive.data(for: entry.path).write(to: destination)
                written += 1
            } catch { fail("writing \(entry.path): \(error)") }
        }
        print("extracted \(written) file(s) to \(outputRoot.path)")
    default:
        usage()
    }

case "tex" where arguments.count >= 3 && arguments[1] == "channels":
    // Mean of each byte position in the first mip, which is what settles how a 4-channel
    // format's bytes are ordered on disk: a flow map's neutral 127 lands in the two
    // positions that hold its direction, and alpha reads 255.
    do {
        let texture = try TEXTexture(data: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        guard let base = texture.mipmaps.first, !base.isEncodedImage else { fail("no raw mip 0") }
        let stride = 4
        var sums = [Double](repeating: 0, count: stride)
        var count = 0
        base.data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index + stride <= bytes.count {
                for channel in 0 ..< stride { sums[channel] += Double(bytes[index + channel]) }
                count += 1
                index += stride
            }
        }
        let format = texture.format.map(String.init(describing:)) ?? "unknown"
        print("format \(format), \(base.width)x\(base.height)")
        for (index, sum) in sums.enumerated() {
            print(String(format: "  byte %d: mean %.1f", index, sum / Double(max(count, 1))))
        }
    } catch { fail("\(error)") }

case "tex":
    guard arguments.count >= 3, arguments[1] == "info" else { usage() }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let texture = try TEXTexture(data: data)
        print("version:   \(texture.version) / \(texture.imageVersion) / \(texture.containerVersion)")
        print("format:    \(texture.format.map(String.init(describing:)) ?? "unknown(\(texture.rawFormat))")")
        print("flags:     \(texture.flags.rawValue)")
        print("mipmaps:   \(texture.mipmaps.count)")
        for (index, mip) in texture.mipmaps.enumerated() {
            print("  [\(index)] \(mip.width)x\(mip.height)  \(byteCount(mip.data.count))\(mip.wasCompressed ? "  (lz4)" : "")")
        }
        if let sheet = texture.spriteSheet {
            print("sprites:   \(sheet.version), \(sheet.frames.count) frame(s)")
        }
    } catch { fail("\(error)") }

case "manifest":
    guard arguments.count >= 2 else { usage() }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: data)
        print("title:      \(manifest.title)")
        print("type:       \(manifest.type.rawValue)")
        print("file:       \(manifest.file ?? "—")")
        print("preview:    \(manifest.preview ?? "—")")
        print("tags:       \(manifest.tags.joined(separator: ", "))")
        let properties = manifest.general?.properties ?? [:]
        print("properties: \(properties.count)")
        for (key, property) in properties.sorted(by: { $0.key < $1.key }) {
            print("  \(key): \(property.type.rawValue)\(property.text.map { " — \($0)" } ?? "")")
        }
    } catch { fail("\(error)") }

case "report":
    guard arguments.count >= 2 else { usage() }
    let libraryRoot = URL(fileURLWithPath: arguments[1])
    var jsonOutput: URL?
    if let flagIndex = arguments.firstIndex(of: "--json"), flagIndex + 1 < arguments.count {
        jsonOutput = URL(fileURLWithPath: arguments[flagIndex + 1])
    }

    do {
        let renderDevice = try RenderDevice.system()
        let scan = LibraryScanner().scan(root: libraryRoot)
        let audit = CompatibilityAudit()
        // One compiler for the whole library. Workshop wallpapers are overwhelmingly built from
        // the same stock shaders, so translating each distinct one once rather than once per
        // wallpaper is the difference between a report that takes seconds and one that does not.
        let sharedCompiler = MaterialCompiler(device: renderDevice.device)

        print("scanned \(scan.scannedDirectories) director\(scan.scannedDirectories == 1 ? "y" : "ies") in \(String(format: "%.2f", scan.duration))s")
        print("indexed \(scan.items.count), playable \(scan.playableCount)\n")

        var entries: [AuditEntry] = []
        var nonScene: [String: Int] = [:]

        for item in scan.items {
            guard item.isPlayable else { continue }
            // Only scenes have anything to audit; video and web either play or they do not,
            // and neither has a compatibility surface worth enumerating.
            guard item.type == .scene, let contentURL = item.contentURL else {
                nonScene[item.type.rawValue, default: 0] += 1
                continue
            }
            entries.append(
                audit.audit(
                    id: item.id, title: item.title, type: item.type.rawValue,
                    directory: item.directory, packageURL: contentURL,
                    device: renderDevice.device, materials: sharedCompiler
                )
            )
        }

        let summary = audit.summarize(entries)

        print("SCENES")
        print("  audited          \(summary.total)")
        print("  renders cleanly  \(summary.supported)  (\(Int(summary.supportedShare * 100))%)")
        print("  partly supported \(summary.degraded)")
        print("  unsupported      \(summary.unsupported)")
        print("  failed to open   \(summary.failed)")
        if summary.total > 0 {
            print("  mean load        \(String(format: "%.0fms", summary.totalSeconds / Double(summary.total) * 1000))")
        }
        for (type, count) in nonScene.sorted(by: { $0.key < $1.key }) {
            print("  \(type): \(count) (not audited)")
        }

        // "Renders cleanly" does not distinguish a wallpaper running the author's shaders from
        // one approximating them, and that distinction is what the transpiler exists to move.
        if summary.totalLayers > 0 {
            print("\nFIDELITY")
            print("  layers               \(summary.totalLayers)")
            print("  running own shaders  \(summary.layersWithOwnShaders)  (\(Int(summary.ownShaderShare * 100))%)")
            let effects = summary.compiledEffects + summary.approximatedEffects
            if effects > 0 {
                print("  effects as written   \(summary.compiledEffects) of \(effects)")
                print("  effects approximated \(summary.approximatedEffects)")
            }
        }

        if !summary.featureImpact.isEmpty {
            print("\nWHAT TO BUILD NEXT — by wallpapers affected")
            for (feature, count) in summary.featureImpact.prefix(12) {
                let share = Int(Double(count) / Double(max(1, summary.total)) * 100)
                let bar = String(repeating: "█", count: max(1, share / 4))
                print(String(format: "  %-24s %4d  %3d%%  %@", (feature as NSString).utf8String!, count, share, bar))
            }
        }

        if !summary.detailImpact.isEmpty {
            print("\nSPECIFICS")
            for (detail, count) in summary.detailImpact.prefix(15) {
                print("  \(count)x  \(detail)")
            }
        }

        let broken = entries.filter { $0.failure != nil || $0.layerCount == 0 }
        if !broken.isEmpty {
            print("\nDID NOT RENDER (\(broken.count))")
            for entry in broken.prefix(20) {
                print("  \(entry.id)  \(entry.title) — \(entry.failure ?? "no drawable layers")")
            }
        }

        if let jsonOutput {
            // Machine-readable so runs can be diffed as the renderer improves; a percentage
            // that only exists in terminal scrollback cannot show progress over time.
            var payload: [[String: Any]] = []
            for entry in entries {
                payload.append([
                    "id": entry.id,
                    "title": entry.title,
                    "level": entry.level.label,
                    "layers": entry.layerCount,
                    // Per wallpaper, not only in the rollup: without these a diff can show the
                    // library-wide number moving without saying which wallpaper improved, which
                    // is the question you actually want answered after a renderer change.
                    "layersWithOwnShaders": entry.layersWithOwnShaders,
                    "compiledEffects": entry.compiledEffects,
                    "approximatedEffects": entry.approximatedEffects,
                    "particleEmitters": entry.particleEmitters,
                    "scripts": entry.scriptCount,
                    "loadMilliseconds": Int(entry.loadSeconds * 1000),
                    "failure": entry.failure as Any,
                    "findings": entry.findings.map {
                        ["level": $0.level.label, "feature": $0.feature, "detail": $0.detail as Any]
                    },
                ])
            }
            // Machine-readable fidelity numbers too, so a later run can be diffed against this
            // one rather than compared by eye.
            let fidelity: [String: Any] = [
                "layers": summary.totalLayers,
                "layersWithOwnShaders": summary.layersWithOwnShaders,
                "compiledEffects": summary.compiledEffects,
                "approximatedEffects": summary.approximatedEffects,
            ]
            let root: [String: Any] = [
                "total": summary.total,
                "supported": summary.supported,
                "degraded": summary.degraded,
                "unsupported": summary.unsupported,
                "failed": summary.failed,
                "featureImpact": summary.featureImpact.map { ["feature": $0.feature, "wallpapers": $0.wallpapers] },
                "fidelity": fidelity,
                "wallpapers": payload,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: jsonOutput)
            print("\nwrote \(jsonOutput.path)")
        }
    } catch { fail("\(error)") }

case "scene":
    guard arguments.count >= 3 else { usage() }
    let subcommand = arguments[1]
    let directory = URL(fileURLWithPath: arguments[2])
    let packageURL = directory.appendingPathComponent("scene.pkg")

    do {
        let renderDevice = try RenderDevice.system()
        // `--no-shaders` draws every layer through the built-in quad shader, which is what the
        // renderer did before materials were compiled. Having both in one binary is what makes
        // the cost of running a wallpaper's own shaders measurable rather than argued about.
        let compileMaterials = !arguments.contains("--no-shaders")
        var scene = try SceneRenderer.loadScene(
            directory: directory,
            packageURL: packageURL,
            wallpaperID: directory.lastPathComponent,
            device: renderDevice.device,
            compileMaterials: compileMaterials
        )
        // `--no-effects` renders the bare composition with every post-process pass removed.
        // Separating the two halves is the only way to tell a scene that composites wrongly
        // from one that composites correctly and is then ruined by an effect chain.
        if arguments.contains("--no-effects") {
            scene.sceneEffects = []
            for index in scene.layers.indices { scene.layers[index].effects = [] }
        }
        // `--only-effect <name>` keeps just the effects whose name contains `name`, so one
        // effect's contribution can be measured against the bare composition. Attributing
        // damage to the effect that caused it is otherwise guesswork in a scene with five.
        if let flag = arguments.firstIndex(of: "--only-effect"), flag + 1 < arguments.count {
            let wanted = arguments[flag + 1].lowercased()
            func keep(_ effect: LayerEffect) -> Bool {
                effect.debugName.lowercased().contains(wanted)
            }
            scene.sceneEffects = scene.sceneEffects.filter(keep)
            for index in scene.layers.indices {
                scene.layers[index].effects = scene.layers[index].effects.filter(keep)
            }
        }

        print("layers:     \(scene.layers.count)")
        if !scene.sceneEffects.isEmpty {
            print("scene effects: \(scene.sceneEffects.map(\.debugName).joined(separator: ", "))")
        } else {
            print("scene effects: none")
        }
        if !scene.particles.isEmpty {
            let total = scene.particles.reduce(0) { $0 + $1.maxCount }
            print("particles:  \(scene.particles.count) emitter(s), up to \(total)")
        }
        print("ortho:      \(Int(scene.orthoSize.x))x\(Int(scene.orthoSize.y))")
        print("clear:      \(scene.clearColor)")
        for layer in scene.layers {
            let texture = layer.texture.map { "\($0.width)x\($0.height)" } ?? "none"
            let effects = layer.effects.isEmpty
                ? ""
                : " effects=[\(layer.effects.map(\.debugName).joined(separator: ","))]"
            print("  \(layer.name)  size=\(Int(layer.size.x))x\(Int(layer.size.y)) "
                  + "origin=(\(Int(layer.origin.x)),\(Int(layer.origin.y))) "
                  + "blend=\(layer.blend) tex=\(texture)\(effects)")
        }

        let findings = scene.report.findings
        print("compatibility: \(scene.report.level.label) — \(scene.report.summary)")
        for finding in findings {
            print("  [\(finding.level)] \(finding.feature)\(finding.detail.map { ": \($0)" } ?? "")")
        }

        if subcommand == "bench" {
            // Renders the same scene repeatedly and reports CPU cost per frame. The absolute
            // number includes an offscreen readback the live path does not do; what it is for
            // is comparing two builds of the same scene, which is why `--no-shaders` exists.
            let frames = arguments.count >= 4 ? (Int(arguments[3]) ?? 120) : 120
            var benchWidth = 1920, benchHeight = 1080
            if let sizeIndex = arguments.firstIndex(of: "--size"), sizeIndex + 1 < arguments.count {
                let parts = arguments[sizeIndex + 1].lowercased().split(separator: "x")
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                    benchWidth = w; benchHeight = h
                }
            }

            let renderer = try SceneRenderer(renderDevice: renderDevice)
            renderer.setScene(scene)

            // Warm up: the first frames pay for pipeline creation and texture residency.
            for _ in 0 ..< 10 {
                _ = renderer.renderOffscreen(width: benchWidth, height: benchHeight)
            }

            var wallSamples: [Double] = []
            var cpuSamples: [Double] = []
            wallSamples.reserveCapacity(frames)
            cpuSamples.reserveCapacity(frames)
            for _ in 0 ..< frames {
                // Thread CPU time, not wall time. The share of a core an idle wallpaper costs is
                // the number PLAN.md §6 is about, and wall time here also counts waiting for the
                // GPU — which is not CPU the user pays for.
                let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let wallStart = ProcessInfo.processInfo.systemUptime
                _ = renderer.renderOffscreen(width: benchWidth, height: benchHeight)
                wallSamples.append((ProcessInfo.processInfo.systemUptime - wallStart) * 1000)
                cpuSamples.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000)
            }

            func summarize(_ samples: [Double]) -> (mean: Double, median: Double, p95: Double) {
                let sorted = samples.sorted()
                return (
                    sorted.reduce(0, +) / Double(sorted.count),
                    sorted[sorted.count / 2],
                    sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                )
            }
            let wall = summarize(wallSamples)
            let cpu = summarize(cpuSamples)

            print()
            print(String(format: "frames:      %d at %dx%d", frames, benchWidth, benchHeight))
            print(String(format: "wall:        %.3f ms median, %.3f p95", wall.median, wall.p95))
            print(String(format: "cpu:         %.3f ms median, %.3f p95", cpu.median, cpu.p95))
            // Includes an offscreen readback the live path does not do, so this is an upper
            // bound rather than the figure a running wallpaper costs.
            print(String(format: "at 30 fps:   %.2f%% of one core (upper bound)", cpu.median * 30 / 10))
            exit(0)
        }

        if subcommand == "render" {
            guard arguments.count >= 4 else { usage() }
            var width = 1920, height = 1080
            if arguments.count >= 5 {
                let parts = arguments[4].lowercased().split(separator: "x")
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                    width = w; height = h
                }
            }
            var pointer = SIMD2<Float>(0, 0)
            if arguments.count >= 6 {
                let parts = arguments[5].split(separator: ",")
                if parts.count == 2, let x = Float(parts[0]), let y = Float(parts[1]) {
                    pointer = SIMD2(x, y)
                }
            }
            let renderer = try SceneRenderer(renderDevice: renderDevice)
            renderer.setScene(scene)
            guard let image = renderer.renderOffscreen(
                width: width, height: height, pointer: pointer, warmUpSeconds: 3
            ) else {
                fail("offscreen render produced no image")
            }
            let outputURL = URL(fileURLWithPath: arguments[3])
            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { fail("could not create \(outputURL.path)") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { fail("could not write PNG") }
            print("rendered \(width)x\(height) to \(outputURL.path)")
        }
    } catch { fail("\(error)") }

case "shader":
    guard arguments.count >= 2 else { usage() }
    let shaderURL = URL(fileURLWithPath: arguments[1])
    let stage: ShaderStage = shaderURL.pathExtension.lowercased() == "vert" ? .vertex : .fragment

    // `--raw` skips preprocessing and hands the file to the backend as written, which is how
    // the emitted GLSL itself gets checked.
    let raw = arguments.contains("--raw")
    let dump = arguments.contains("--dump-glsl")

    do {
        var glsl = try String(contentsOf: shaderURL, encoding: .utf8)
        var prepared: PreprocessedShader?

        if !raw {
            let source = ShaderSource(
                name: shaderURL.lastPathComponent, stage: stage, text: glsl
            )
            let provider = DirectoryShaderFileProvider(
                root: shaderURL.deletingLastPathComponent()
            )
            let processed = try ShaderPreprocessor().preprocess(source, provider: provider)
            glsl = processed.glsl
            prepared = processed

            for diagnostic in processed.diagnostics {
                FileHandle.standardError.write(Data("\(diagnostic)\n".utf8))
            }
        }

        if dump {
            print(glsl)
            exit(0)
        }

        let backend = TranspilerBackendFactory.makeDefault()
        if backend is UnavailableTranspilerBackend {
            fail("shader toolchain not built — run Scripts/vendor-shader-tools.sh")
        }
        let translated: TranspiledShader
        do {
            translated = try backend.compile(glsl: glsl, stage: stage)
        } catch let error as TranspilerBackendError {
            // Report the author's line, not the emitted one: the prologue shifted everything
            // and includes were flattened, so the raw number names a line nobody can find.
            if case .translationFailed(_, let detail) = error, let prepared {
                fail(remapDiagnosticLines(detail, in: prepared))
            }
            fail("\(error)")
        }

        if let prepared, !prepared.layout.isEmpty {
            print("// uniform block: \(prepared.layout.size) bytes")
            let translated = translated.reflection.members
            for member in prepared.layout.members {
                let count = member.arrayLength.map { "[\($0)]" } ?? ""
                // Disagreement here means every uniform after the first mismatch is written
                // to the wrong place, so it is worth saying loudly rather than only in tests.
                let reported = translated.first { $0.name == member.name }?.offset
                let agreement = switch reported {
                case .none: "  (eliminated)"
                case .some(member.offset): ""
                case .some(let other): "  MISMATCH: translator says +\(other)"
                }
                print("//   +\(member.offset)\t\(member.type.rawValue) \(member.name)\(count)\(agreement)")
            }
        }
        print("// \(shaderURL.lastPathComponent) -> Metal (\(stage.rawValue))")
        print("// entry point: \(translated.reflection.entryPoint)")
        for buffer in translated.reflection.buffers {
            print("// buffer(\(buffer.slot)): \(buffer.name)")
        }
        for texture in translated.reflection.textures {
            print("// texture(\(texture.slot)): \(texture.name)")
        }
        for sampler in translated.reflection.samplers {
            print("// sampler(\(sampler.slot)): \(sampler.name)")
        }
        for input in translated.reflection.inputs {
            print("// in(\(input.location)): \(input.name) x\(input.components)")
        }
        print(translated.msl)
    } catch { fail("\(error)") }

case "library":
    // Reports what the app has stored about the user's library folder, and whether it can still
    // be reached. Deliberately runs from `wetool` rather than the app: the two are signed
    // separately, so this also exercises the case a security-scoped bookmark cannot survive —
    // a build whose code signature differs from the one that wrote it.
    let domain = arguments.count >= 2 ? arguments[1] : "app.diorama.Diorama"
    guard let defaults = UserDefaults(suiteName: domain) else {
        fail("could not open the preferences domain \(domain)")
    }
    print("domain:     \(domain)")
    print("sandboxed:  \(LibraryStore.isSandboxed)")
    print("writes:     \(LibraryStore.bookmarkCreationOptions.isEmpty ? "plain bookmarks" : "security-scoped bookmarks")")

    guard let bookmark = defaults.data(forKey: "libraryBookmark") else {
        print("bookmark:   none stored — no library has been imported")
        exit(0)
    }
    print("bookmark:   \(bookmark.count) bytes")

    do {
        let resolved = try LibraryStore.resolveBookmark(bookmark)
        print("resolves:   yes\(resolved.isStale ? " (stale — will be rewritten on next open)" : "")")
        print("folder:     \(resolved.url.path)")

        let exists = FileManager.default.fileExists(atPath: resolved.url.path)
        print("exists:     \(exists)")
        if exists {
            let scan = LibraryScanner().scan(root: resolved.url)
            print("indexed:    \(scan.items.count), playable \(scan.playableCount)")
        }
    } catch {
        print("resolves:   NO — \(error.localizedDescription)")
        print("            The app will report the folder as lost and ask for it again.")
        exit(1)
    }

case "-h", "--help", "help":
    usage()

default:
    usage()
}
