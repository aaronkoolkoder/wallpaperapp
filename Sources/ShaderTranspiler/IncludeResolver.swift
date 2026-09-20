import Foundation

// MARK: - File provider

/// Supplies the text of an `#include`d shader file.
///
/// Wallpaper Engine shaders include helpers by bare name (`#include "common.h"`), which
/// the engine resolves against its shader include directory. Keeping that behind a
/// protocol means the resolver is testable in memory today and can be backed by a `.pkg`
/// archive entry reader later without touching this file.
public protocol ShaderFileProvider: Sendable {
    func contents(of name: String) throws -> String
}

public enum ShaderFileProviderError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound(String)
    case unsafePath(String)
    case undecodableText(String)

    public var description: String {
        switch self {
        case .notFound(let name): "shader include not found: \(name)"
        case .unsafePath(let name): "shader include path escapes the include root: \(name)"
        case .undecodableText(let name): "shader include is not decodable text: \(name)"
        }
    }
}

/// In-memory include provider, for tests and for archives already fully unpacked.
public struct InMemoryShaderFileProvider: ShaderFileProvider {
    private let files: [String: String]
    private let normalized: [String: String]

    public init(_ files: [String: String]) {
        self.files = files
        var normalized: [String: String] = [:]
        for (name, text) in files {
            normalized[IncludeResolver.canonicalKey(name)] = text
        }
        // Basename fallback: shaders say `#include "common.h"` while an archive may key
        // the entry as `shaders/common.h`.
        // TODO(verify): confirm against real .pkg content whether include names are ever
        // written with a directory prefix, and whether the engine searches subdirectories.
        for (name, text) in files {
            let base = IncludeResolver.canonicalKey((name as NSString).lastPathComponent)
            if normalized[base] == nil { normalized[base] = text }
        }
        self.normalized = normalized
    }

    public func contents(of name: String) throws -> String {
        if let exact = files[name] { return exact }
        if let byKey = normalized[IncludeResolver.canonicalKey(name)] { return byKey }
        let base = IncludeResolver.canonicalKey((name as NSString).lastPathComponent)
        if let byBase = normalized[base] { return byBase }
        throw ShaderFileProviderError.notFound(name)
    }
}

/// Include provider backed by a directory on disk.
public struct DirectoryShaderFileProvider: ShaderFileProvider {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func contents(of name: String) throws -> String {
        // Include names come from untrusted Workshop content; never let one walk out of
        // the include root.
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"),
              !normalized.split(separator: "/").contains("..")
        else {
            throw ShaderFileProviderError.unsafePath(name)
        }
        let url = root.appending(path: normalized)
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else {
            throw ShaderFileProviderError.notFound(name)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Windows-authored shaders occasionally carry Latin-1 bytes in comments.
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw ShaderFileProviderError.undecodableText(name)
    }
}

// MARK: - Errors

public enum IncludeError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A file includes itself, directly or through a chain. `chain` is the include stack
    /// with the repeated file appended, so the loop is visible in the message.
    case cycleDetected(chain: [String])

    /// The include nesting went deeper than the configured limit.
    case maxDepthExceeded(limit: Int, chain: [String])

    /// The provider could not supply an included file. `includeStack` is the chain of
    /// files that led here, innermost last.
    case fileNotFound(name: String, includeStack: [String], reason: String)

    public var description: String {
        switch self {
        case .cycleDetected(let chain):
            "include cycle: \(chain.joined(separator: " -> "))"
        case .maxDepthExceeded(let limit, let chain):
            "include nesting exceeded \(limit) levels: \(chain.joined(separator: " -> "))"
        case .fileNotFound(let name, let stack, let reason):
            "missing include \"\(name)\" (from \(stack.joined(separator: " -> "))): \(reason)"
        }
    }
}

// MARK: - Result

/// Include-expanded shader text plus the mapping back to where each line came from.
public struct ResolvedShaderSource: Sendable, Hashable {
    /// Flattened text with every `#include` replaced by the included file's lines.
    public var text: String

    /// `lineMap[i]` is the original location of line `i + 1` of `text`.
    public var lineMap: [SourceLocation]

    /// Every file pulled in, in first-inclusion order.
    public var includedFiles: [String]

    public init(text: String, lineMap: [SourceLocation], includedFiles: [String]) {
        self.text = text
        self.lineMap = lineMap
        self.includedFiles = includedFiles
    }

    /// Original location of a 1-based line in `text`.
    public func origin(ofLine line: Int) -> SourceLocation? {
        guard line >= 1, line <= lineMap.count else { return nil }
        return lineMap[line - 1]
    }
}

// MARK: - Resolver

/// Expands Wallpaper Engine `#include "..."` directives.
///
/// Deliberately *not* a full C preprocessor: it does not evaluate `#if`, so an include
/// inside a disabled conditional block is still expanded. That is safe (the guarded code
/// is still skipped by the real preprocessor downstream) but it means include cycles
/// which the real engine would break via `#ifdef` guards are reported as cycles here.
///
/// `TODO(verify):` whether Wallpaper Engine's preprocessor evaluates conditionals before
/// resolving includes, and whether its include is include-once by default.
public struct IncludeResolver: Sendable {
    /// Default nesting limit. Real shader packs nest two or three levels; 32 is a
    /// runaway guard, not a real constraint.
    public static let defaultMaxDepth = 32

    /// Maximum number of nested include levels. The root file is level 0.
    public var maxDepth: Int

    /// When true, a file already expanded anywhere in this resolution is skipped on
    /// subsequent includes (C++ `#pragma once` semantics).
    ///
    /// `TODO(verify):` defaults to `false` (plain textual inclusion) because that is what
    /// the C preprocessor does and what shipped shaders' own `#ifndef` guards imply. If
    /// real content turns out to rely on include-once, flip this default.
    public var includeOnce: Bool

    /// Files expanded at most once regardless of `includeOnce`.
    ///
    /// Holds the implicit common header, which the preprocessor prepends to every shader.
    public var alwaysOnce: Set<String>

    public init(
        maxDepth: Int = IncludeResolver.defaultMaxDepth,
        includeOnce: Bool = false,
        alwaysOnce: Set<String> = ["common.h"]
    ) {
        self.maxDepth = max(0, maxDepth)
        self.includeOnce = includeOnce
        self.alwaysOnce = Set(alwaysOnce.map(IncludeResolver.canonicalKey))
    }

    /// - Parameter prelude: files expanded ahead of `source`, as Wallpaper Engine's compiler
    ///   prepends its common header. They are expanded *before* the source and registered as
    ///   already-seen, so the source's own line numbers are untouched — prepending an
    ///   `#include` line to the text instead shifts every one of them by one, and every
    ///   compiler error then points at the line after the real one.
    public func resolve(
        _ source: ShaderSource,
        provider: ShaderFileProvider,
        prelude: [String] = []
    ) throws -> ResolvedShaderSource {
        var lines: [String] = []
        var lineMap: [SourceLocation] = []
        var included: [String] = []
        var alreadyExpanded: Set<String> = []
        var stack: [String] = []

        for name in prelude {
            let text: String
            if let provided = try? provider.contents(of: name) {
                text = provided
            } else if let builtin = BuiltinShaderLibrary.header(named: name) {
                text = builtin
            } else {
                continue
            }
            try expand(
                text: text,
                file: name,
                provider: provider,
                depth: 0,
                stack: &stack,
                lines: &lines,
                lineMap: &lineMap,
                included: &included,
                alreadyExpanded: &alreadyExpanded
            )
            alreadyExpanded.insert(Self.canonicalKey(name))
            if !included.contains(name) { included.append(name) }
        }

        try expand(
            text: source.text,
            file: source.name,
            provider: provider,
            depth: 0,
            stack: &stack,
            lines: &lines,
            lineMap: &lineMap,
            included: &included,
            alreadyExpanded: &alreadyExpanded
        )

        return ResolvedShaderSource(
            text: SourceText.join(lines),
            lineMap: lineMap,
            includedFiles: included
        )
    }

    private func expand(
        text: String,
        file: String,
        provider: ShaderFileProvider,
        depth: Int,
        stack: inout [String],
        lines: inout [String],
        lineMap: inout [SourceLocation],
        included: inout [String],
        alreadyExpanded: inout Set<String>
    ) throws {
        let key = Self.canonicalKey(file)
        if stack.contains(where: { Self.canonicalKey($0) == key }) {
            throw IncludeError.cycleDetected(chain: stack + [file])
        }
        if depth > maxDepth {
            throw IncludeError.maxDepthExceeded(limit: maxDepth, chain: stack + [file])
        }

        stack.append(file)
        defer { stack.removeLast() }

        // Block-comment state is per file: an include cannot legally straddle one.
        var splitter = CommentSplitter()

        for (offset, rawLine) in SourceText.lines(of: text).enumerated() {
            let lineNumber = offset + 1
            let scan = splitter.scan(rawLine)

            guard let target = Self.includeTarget(inCode: scan.code) else {
                lines.append(rawLine)
                lineMap.append(SourceLocation(file: file, line: lineNumber))
                continue
            }

            let targetKey = Self.canonicalKey(target)
            // The implicit header is always include-once, whatever the resolver's general
            // policy. It is prepended to every shader, so a wallpaper that also includes it by
            // name would get it twice — and a copy without an include guard, which shipped ones
            // routinely lack, then redefines every function in it.
            let isImplicit = alwaysOnce.contains(targetKey)
            if includeOnce || isImplicit, alreadyExpanded.contains(targetKey) {
                // Keep a blank line so the file's own line count is unchanged.
                lines.append("")
                lineMap.append(SourceLocation(file: file, line: lineNumber))
                continue
            }

            let includedText: String
            do {
                includedText = try provider.contents(of: target)
            } catch {
                // Wallpaper Engine's own headers live in its application, not inside a
                // wallpaper, so nothing downloaded from the Workshop carries them. Falling back
                // here rather than in each provider means every caller gets them — and the
                // wallpaper's own copy still wins, because this is only reached when the
                // provider has none.
                if let builtin = BuiltinShaderLibrary.header(named: target) {
                    includedText = builtin
                } else {
                    throw IncludeError.fileNotFound(
                        name: target,
                        includeStack: stack,
                        reason: String(describing: error)
                    )
                }
            }

            alreadyExpanded.insert(targetKey)
            if !included.contains(target) { included.append(target) }

            try expand(
                text: includedText,
                file: target,
                provider: provider,
                depth: depth + 1,
                stack: &stack,
                lines: &lines,
                lineMap: &lineMap,
                included: &included,
                alreadyExpanded: &alreadyExpanded
            )
        }
    }

    /// Extracts the include target from a line of code, or `nil` if it is not an include.
    ///
    /// Accepts `#include "name"` and `#include <name>`. `TODO(verify):` only the quoted
    /// form has been described for Wallpaper Engine; the angle form is accepted because
    /// rejecting it would be a silent shader break if it does occur.
    static func includeTarget(inCode code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }

        var rest = trimmed.dropFirst().drop { $0 == " " || $0 == "\t" }
        guard rest.hasPrefix("include") else { return nil }
        rest = rest.dropFirst("include".count)
        if let next = rest.first, !(next.isWhitespace || next == "\"" || next == "<") {
            return nil
        }
        rest = rest.drop { $0.isWhitespace }

        guard let open = rest.first else { return nil }
        let close: Character
        switch open {
        case "\"": close = "\""
        case "<": close = ">"
        default: return nil
        }

        let body = rest.dropFirst()
        guard let end = body.firstIndex(of: close) else { return nil }
        let name = String(body[..<end]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Normalizes an include name for identity comparisons.
    ///
    /// `TODO(verify):` Wallpaper Engine is a Windows application, so its include lookup is
    /// almost certainly case-insensitive. We lowercase for identity, which means a pack
    /// that genuinely relies on case-distinct include names would be mis-detected as a
    /// cycle. That trade is deliberate: false-positive cycle beats infinite expansion.
    static func canonicalKey(_ name: String) -> String {
        var normalized = name.replacingOccurrences(of: "\\", with: "/")
        while normalized.hasPrefix("./") { normalized.removeFirst(2) }
        return normalized.lowercased()
    }
}
