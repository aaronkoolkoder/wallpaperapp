import Foundation

/// One file inside a `.pkg` container.
public struct PKGEntry: Sendable, Hashable {

    /// Normalised, archive-relative path — always forward slashes, never absolute,
    /// never containing a `..` component. See ``PKGArchive/normalizedPath(_:)``.
    public let path: String

    /// Byte offset of this entry's payload, **relative to the end of the header block**,
    /// which is how the container stores it. ``PKGArchive/headerEnd`` converts it to an
    /// absolute position.
    public let offset: Int

    /// Payload length in bytes.
    public let size: Int

    public init(path: String, offset: Int, size: Int) {
        self.path = path
        self.offset = offset
        self.size = size
    }
}

/// Reader for the Wallpaper Engine `.pkg` container (`scene.pkg` and friends).
///
/// The container is a flat, *uncompressed* archive: a version signature, a table of
/// `(path, offset, size)` records, then one contiguous blob. Entry offsets are relative
/// to the end of the header table, not to the start of the file, so the parse computes
/// that boundary once (``headerEnd``) and stores it rather than re-deriving it per read.
///
/// Layout, per PLAN.md §4.2:
///
/// ```text
/// int32   headerVersionLength
/// char[]  headerVersion          // "PKGV" + four digits, not NUL-terminated
/// int32   entryCount
/// entry × entryCount {
///   int32  pathLength
///   char[] path
///   int32  offset                // relative to end of header block
///   int32  size
/// }
/// byte[]  blob
/// ```
public struct PKGArchive: Sendable {

    /// Whether this reader will attempt a container revision.
    ///
    /// Any `PKGV` revision, rather than a fixed list. A real Workshop library turned out to
    /// contain every revision from `PKGV0001` to `PKGV0024`, and all of them share the same
    /// three-field entry record — checked by parsing one of each and confirming the entry
    /// table lands exactly on the end of the blob. The number tracks the editor's own
    /// versioning, not the container layout.
    ///
    /// Refusing unknown revisions cost 85% of the scenes in that library, so the reader
    /// validates *structure* instead: paths are normalised and rejected if they could escape,
    /// offsets and sizes are range-checked against the blob, and duplicates are resolved. A
    /// revision that genuinely changed layout fails those checks loudly rather than yielding
    /// garbage, which is the behaviour a version allowlist was there to guarantee anyway.
    public static func isSupportedVersion(_ version: String) -> Bool {
        guard version.count == 8, version.hasPrefix("PKGV") else { return false }
        return version.dropFirst(4).allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Shape of one entry record for a given container revision.
    ///
    /// Every revision observed in a real Workshop library — `PKGV0001` through `PKGV0024` —
    /// uses the same three-field record, so `trailingInt32Count` is `0` throughout. The
    /// dispatch stays because it is where a genuine layout change would be handled.
    ///
    /// - TODO: Unverified. PLAN.md documents one record shape for all five revisions, and
    ///   no real v2–v5 archive was available to confirm it. If a future archive fails with
    ///   an "outside the blob" error while its entry table looks plausible, the likely
    ///   cause is an extra trailing field in that revision — add it here rather than by
    ///   loosening the range validation, which exists to catch exactly this mistake.
    struct EntryLayout: Sendable {
        /// Extra `int32` fields following `size` in this revision's entry record.
        let trailingInt32Count: Int

        /// Smallest possible on-disk size of one record (zero-length path).
        var minimumRecordSize: Int { 4 /* pathLength */ + 4 /* offset */ + 4 /* size */ + trailingInt32Count * 4 }
    }

    /// Header signature exactly as it appeared in the file, e.g. `"PKGV0004"`.
    public let version: String

    /// Absolute byte offset of the first payload byte — the origin every
    /// ``PKGEntry/offset`` is measured from.
    public let headerEnd: Int

    /// Entries in file order. Every entry has been validated to lie inside the blob.
    public let entries: [PKGEntry]

    private let buffer: Data
    private let index: [String: Int]

    // MARK: - Parsing

    /// Parses a `.pkg` container held entirely in memory.
    ///
    /// The whole entry table is validated up front — paths normalised, ranges checked
    /// against the blob — so callers can enumerate ``entries`` without re-validating and
    /// ``data(for:)`` never has to fail on a range it already accepted.
    public init(data: Data) throws {
        var reader = BinaryReader(data)

        let version = try reader.readLengthPrefixedString()
        guard Self.isSupportedVersion(version) else {
            throw WEError.badMagic(expected: "PKGV followed by four digits", found: version)
        }
        let layout = Self.entryLayout(for: version)

        let entryCountField = try reader.readInt32()
        let entryCount = try reader.validatedCount(
            entryCountField,
            elementStride: layout.minimumRecordSize,
            field: "entryCount"
        )

        var entries: [PKGEntry] = []
        // Bounded reserve: `entryCount` is already known to fit the buffer, but a 100 MB
        // archive of empty files could still name a few million entries.
        entries.reserveCapacity(min(entryCount, 4096))

        for i in 0 ..< entryCount {
            let rawPath = try reader.readLengthPrefixedString()
            let offset = Int(try reader.readInt32())
            let size = Int(try reader.readInt32())
            if layout.trailingInt32Count > 0 {
                try reader.skip(layout.trailingInt32Count * 4)
            }

            let path: String
            do {
                path = try Self.normalizedPath(rawPath)
            } catch let error as WEError {
                throw error.prefixed("entry \(i)")
            }

            guard offset >= 0 else {
                throw WEError.corruptField("entry \(i) (\(path)) has negative offset \(offset)")
            }
            guard size >= 0 else {
                throw WEError.corruptField("entry \(i) (\(path)) has negative size \(size)")
            }
            entries.append(PKGEntry(path: path, offset: offset, size: size))
        }

        let headerEnd = reader.offset
        let blobSize = data.count - headerEnd

        for entry in entries {
            let (end, overflow) = entry.offset.addingReportingOverflow(entry.size)
            guard !overflow, end <= blobSize else {
                throw WEError.corruptField(
                    "entry \"\(entry.path)\" spans \(entry.offset)..<\(entry.offset + entry.size) "
                    + "but the blob is only \(blobSize) byte(s)"
                )
            }
        }

        // First occurrence wins. Duplicate paths are malformed rather than meaningful,
        // and silently preferring the later one would let a crafted archive shadow a
        // legitimate resource.
        var index: [String: Int] = [:]
        index.reserveCapacity(entries.count)
        for (i, entry) in entries.enumerated() where index[entry.path] == nil {
            index[entry.path] = i
        }

        self.version = version
        self.headerEnd = headerEnd
        self.entries = entries
        self.buffer = data
        self.index = index
    }

    /// Convenience loader. Uses a memory-mapped read where the OS allows it, since a
    /// `scene.pkg` is routinely tens of megabytes and is read once at import.
    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    // MARK: - Access

    /// All entry paths, in file order.
    public var paths: [String] { entries.map(\.path) }

    /// Whether the archive holds `path`. Accepts Windows-style separators — content
    /// authored on Windows references `"materials\\wave.json"` about as often as not.
    public func contains(_ path: String) -> Bool {
        guard let key = try? Self.normalizedPath(path) else { return false }
        return index[key] != nil
    }

    /// Payload bytes for `path`.
    ///
    /// - Throws: ``WEError/corruptField(_:)`` when no such entry exists. The range itself
    ///   was validated during ``init(data:)``, so this cannot fail on bounds.
    public func data(for path: String) throws -> Data {
        guard let key = try? Self.normalizedPath(path), let i = index[key] else {
            throw WEError.corruptField("no entry named \"\(path)\"")
        }
        let entry = entries[i]
        let reader = BinaryReader(buffer, allocationLimit: max(entry.size, 1))
        return try reader.slice(at: headerEnd + entry.offset, length: entry.size)
    }

    /// Non-throwing lookup, for the common "use it if it's there" case.
    public subscript(path: String) -> Data? { try? data(for: path) }

    // MARK: - Internals

    /// Shape of one entry record.
    ///
    /// The same for every revision observed so far (PKGV0001 through PKGV0024). Kept as a
    /// dispatch point rather than inlined because if a future revision does add a field, this
    /// is where it goes — and the range checks downstream are what will point at it.
    static func entryLayout(for version: String) -> EntryLayout {
        EntryLayout(trailingInt32Count: 0)
    }

    /// Normalises an archive path and rejects anything that could escape an extraction
    /// directory.
    ///
    /// Workshop archives are untrusted, and the obvious attack on any container reader is
    /// an entry named `../../../../Library/LaunchAgents/x.plist`. Separators are unified
    /// to `/`, `.` components dropped, and absolute paths, drive letters, `..` components
    /// and embedded control characters all rejected outright — no sanitising-by-stripping,
    /// which historically just moves the bug around.
    static func normalizedPath(_ raw: String) throws -> String {
        guard !raw.isEmpty else { throw WEError.corruptField("empty entry path") }
        guard !raw.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw WEError.corruptField("entry path contains control characters")
        }

        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        guard !unified.hasPrefix("/") else {
            throw WEError.corruptField("absolute entry path \"\(raw)\"")
        }
        guard !unified.contains(":") else {
            throw WEError.corruptField("entry path \"\(raw)\" names a volume or drive")
        }

        let components = unified
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
        guard !components.isEmpty else {
            throw WEError.corruptField("entry path \"\(raw)\" has no usable components")
        }
        guard !components.contains("..") else {
            throw WEError.corruptField("entry path \"\(raw)\" escapes the archive root")
        }
        return components.joined(separator: "/")
    }
}

extension WEError {
    /// Adds locating context to a field error raised deep in a table walk.
    func prefixed(_ context: String) -> WEError {
        if case let .corruptField(detail) = self {
            return .corruptField("\(context): \(detail)")
        }
        return self
    }
}
