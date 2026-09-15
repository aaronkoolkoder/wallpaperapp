import Foundation

/// Every failure the `WEFormat` decoders can produce.
///
/// Wallpaper Engine content is arbitrary third-party data downloaded from the Steam
/// Workshop and parsed by a process that runs continuously in the background, so no
/// decoder in this module is allowed to trap. Malformed input always surfaces as one
/// of these cases, and the intended caller behaviour is "skip this wallpaper and record
/// the reason in the compatibility report" — never a crash.
public enum WEError: Error, Equatable, Sendable {

    /// A read ran past the end of the buffer.
    ///
    /// - Parameters:
    ///   - offset: Reader position where the read was attempted.
    ///   - needed: Bytes the read wanted.
    ///   - available: Bytes actually left in the buffer.
    case truncated(offset: Int, needed: Int, available: Int)

    /// A fixed signature did not match. `found` is rendered with non-printable bytes
    /// replaced by `.` so it is always safe to log.
    case badMagic(expected: String, found: String)

    /// A well-formed signature naming a container revision this module does not decode.
    case unsupportedVersion(String)

    /// A field parsed cleanly but holds a value the format cannot mean — a negative
    /// length, an entry pointing outside the blob, a traversing path.
    case corruptField(String)

    /// A count or length would have required an allocation larger than the buffer could
    /// justify. Checked *before* allocating: a corrupt `entryCount` must never turn into
    /// a multi-gigabyte reserve.
    case allocationTooLarge(Int)

    /// An LZ4 block failed to decode, or decoded to a size other than the one the
    /// mipmap header declared.
    case decompressionFailed
}

extension WEError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .truncated(offset, needed, available):
            return "truncated at offset \(offset): needed \(needed) byte(s), \(available) available"
        case let .badMagic(expected, found):
            return "bad magic: expected \"\(expected)\", found \"\(found)\""
        case let .unsupportedVersion(version):
            return "unsupported version \"\(version)\""
        case let .corruptField(detail):
            return "corrupt field: \(detail)"
        case let .allocationTooLarge(bytes):
            return "refusing to allocate \(bytes) byte(s)"
        case .decompressionFailed:
            return "LZ4 decompression failed"
        }
    }
}

extension WEError: LocalizedError {
    public var errorDescription: String? { description }
}
