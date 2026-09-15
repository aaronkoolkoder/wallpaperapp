import Foundation

/// A bounds-checked, little-endian cursor over a byte buffer.
///
/// Wallpaper Engine's binary formats are little-endian and length-prefixed, which makes
/// them trivially exploitable if lengths are trusted: a two-byte edit turns a 40 KB
/// `.tex` into a request for a 2 GB allocation. Every read here validates against the
/// bytes actually remaining *before* it allocates anything, and every failure is a typed
/// ``WEError`` rather than a trap.
///
/// The reader keeps its own `offset`, so `Data` slices with a non-zero `startIndex`
/// (what you get back from `Data.subdata` or a range subscript) behave identically to
/// whole buffers — a recurring source of off-by-`startIndex` bugs when parsing.
public struct BinaryReader: Sendable {

    /// Ceiling for any single length-driven allocation, 256 MiB.
    ///
    /// Comfortably above the largest legitimate payload we expect (an uncompressed
    /// 4K ARGB8888 mipmap is 32 MiB) and far below the point where a corrupt length
    /// becomes a denial of service.
    public static let maxReasonableAllocation = 256 << 20

    private let buffer: Data
    /// `buffer.startIndex`, cached so index arithmetic stays honest for slices.
    private let base: Int

    /// Per-reader override of ``maxReasonableAllocation``.
    public let allocationLimit: Int

    /// Bytes consumed so far, always relative to the start of this reader's buffer.
    public private(set) var offset: Int

    public init(_ data: Data, allocationLimit: Int = BinaryReader.maxReasonableAllocation) {
        self.buffer = data
        self.base = data.startIndex
        self.allocationLimit = max(0, allocationLimit)
        self.offset = 0
    }

    public init(_ bytes: [UInt8], allocationLimit: Int = BinaryReader.maxReasonableAllocation) {
        self.init(Data(bytes), allocationLimit: allocationLimit)
    }

    // MARK: - Position

    /// Total size of the buffer.
    public var count: Int { buffer.count }

    /// Bytes left between ``offset`` and the end of the buffer.
    public var remaining: Int { count - offset }

    public var isAtEnd: Bool { remaining <= 0 }

    /// Whether `n` more bytes can be read without failing. Non-throwing, for probing
    /// optional trailing sections such as a `.tex` sprite table.
    public func canRead(_ n: Int) -> Bool { n >= 0 && n <= remaining }

    /// Moves the cursor to an absolute position, which must be inside the buffer.
    public mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= count else {
            throw WEError.truncated(offset: newOffset, needed: 0, available: count)
        }
        offset = newOffset
    }

    /// Advances the cursor past `n` bytes.
    public mutating func skip(_ n: Int) throws {
        try requireBytes(n)
        offset += n
    }

    // MARK: - Scalars

    public mutating func readUInt32() throws -> UInt32 {
        try requireBytes(4)
        let i = base + offset
        let value = UInt32(buffer[i])
            | UInt32(buffer[i + 1]) << 8
            | UInt32(buffer[i + 2]) << 16
            | UInt32(buffer[i + 3]) << 24
        offset += 4
        return value
    }

    public mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    /// Reads an IEEE-754 single-precision float. Wallpaper Engine stores frame durations
    /// and sprite quads this way.
    public mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    // MARK: - Blocks

    /// Reads `count` bytes.
    ///
    /// The result is a fresh `Data` with a zero `startIndex` rather than a slice of the
    /// backing buffer, so callers can index it from 0 without inheriting this reader's
    /// base offset.
    public mutating func readBytes(count n: Int) throws -> Data {
        guard n >= 0 else { throw WEError.corruptField("negative byte count \(n)") }
        try requireBytes(n)
        guard n <= allocationLimit else { throw WEError.allocationTooLarge(n) }
        let start = base + offset
        let bytes = Data(buffer[start ..< start + n])
        offset += n
        return bytes
    }

    /// Reads an `int32` length followed by exactly that many non-null-terminated bytes.
    ///
    /// This is how `.pkg` stores both its header signature and every entry path. The
    /// bytes are documented as ASCII but are decoded permissively as UTF-8 with
    /// replacement characters: a mojibake path should degrade to an unusable-but-visible
    /// name in the compatibility report, not abort the scan of an entire archive.
    public mutating func readLengthPrefixedString() throws -> String {
        let lengthField = try readInt32()
        guard lengthField >= 0 else {
            throw WEError.corruptField("negative string length \(lengthField)")
        }
        let bytes = try readBytes(count: Int(lengthField))
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads a fixed-width signature followed by its NUL terminator, e.g. `"TEXV0005\0"`.
    ///
    /// `.tex` writes its magics as a fixed number of characters plus a terminator rather
    /// than length-prefixing them, so the width has to be supplied by the caller.
    /// Non-printable bytes are rendered as `.` in the returned string, which keeps the
    /// value safe to embed in a ``WEError/badMagic(expected:found:)`` message.
    public mutating func readNullTerminatedMagic(expectedLength: Int = 8) throws -> String {
        guard expectedLength >= 0 else {
            throw WEError.corruptField("negative magic length \(expectedLength)")
        }
        try requireBytes(expectedLength + 1)
        let start = base + offset
        let scalars = buffer[start ..< start + expectedLength].map { byte -> Character in
            (0x20 ... 0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
        }
        let terminator = buffer[start + expectedLength]
        guard terminator == 0 else {
            throw WEError.corruptField(
                "magic \"\(String(scalars))\" is not NUL-terminated (found 0x\(String(terminator, radix: 16)))"
            )
        }
        offset += expectedLength + 1
        return String(scalars)
    }

    /// Non-consuming look at a fixed-width signature, without requiring a terminator.
    ///
    /// Used to decide whether an optional trailing block (`TEXS…`) is present at all.
    /// Returns `nil` when fewer than `length` bytes remain.
    public func peekMagic(length: Int = 8) -> String? {
        guard length >= 0, canRead(length) else { return nil }
        let start = base + offset
        let scalars = buffer[start ..< start + length].map { byte -> Character in
            (0x20 ... 0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
        }
        return String(scalars)
    }

    // MARK: - Validation helpers

    /// Validates an element count read from the file before anything is allocated for it.
    ///
    /// Rejects the two shapes that matter: a negative count, and a count whose elements
    /// could not physically fit in the bytes that remain (`entryCount = Int32.max` in a
    /// 64-byte file). Callers still need `reserveCapacity` discipline, but they can rely
    /// on the returned value being bounded by the buffer.
    ///
    /// - Parameter elementStride: Smallest possible on-disk size of one element.
    public func validatedCount(_ raw: Int32, elementStride: Int, field: String) throws -> Int {
        guard raw >= 0 else { throw WEError.corruptField("\(field) is negative (\(raw))") }
        let n = Int(raw)
        let stride = max(elementStride, 1)
        guard n <= remaining / stride else { throw WEError.allocationTooLarge(n * stride) }
        guard n * stride <= allocationLimit else { throw WEError.allocationTooLarge(n * stride) }
        return n
    }

    /// Absolute-range read that does not move the cursor, for formats that address their
    /// payload by offset rather than by position — `.pkg` entries, specifically.
    public func slice(at start: Int, length: Int) throws -> Data {
        guard start >= 0, length >= 0 else {
            throw WEError.corruptField("negative slice (start \(start), length \(length))")
        }
        guard length <= allocationLimit else { throw WEError.allocationTooLarge(length) }
        guard let end = addingIfNoOverflow(start, length), end <= count else {
            throw WEError.truncated(offset: start, needed: length, available: max(0, count - start))
        }
        return Data(buffer[base + start ..< base + end])
    }

    // MARK: - Private

    private func requireBytes(_ n: Int) throws {
        guard n >= 0 else { throw WEError.corruptField("negative read length \(n)") }
        guard n <= remaining else {
            throw WEError.truncated(offset: offset, needed: n, available: max(0, remaining))
        }
    }

    private func addingIfNoOverflow(_ a: Int, _ b: Int) -> Int? {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : sum
    }
}
