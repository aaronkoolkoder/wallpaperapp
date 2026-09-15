import Foundation
import LibraryKit
import WEFormat

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

case "-h", "--help", "help":
    usage()

default:
    usage()
}
