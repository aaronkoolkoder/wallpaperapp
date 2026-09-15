import Foundation
@testable import WEFormat

/// Synthesizes valid `.pkg` byte buffers so the reader can be round-tripped without shipping
/// Steam Workshop content into the repo (which would not be redistributable — see PLAN.md §11.2).
struct PKGBuilder {
    var version: String
    var files: [(path: String, contents: Data)] = []
    /// Extra int32 fields per entry record, for the later header revisions.
    var trailingInt32Count: Int = 0

    init(version: String = "PKGV0001", trailingInt32Count: Int = 0) {
        self.version = version
        self.trailingInt32Count = trailingInt32Count
    }

    mutating func add(_ path: String, _ contents: String) {
        files.append((path, Data(contents.utf8)))
    }

    mutating func add(_ path: String, _ contents: Data) {
        files.append((path, contents))
    }

    func build() -> Data {
        var header = Data()
        header.appendLengthPrefixed(version)
        header.appendInt32(Int32(files.count))

        var blob = Data()
        var offsets: [(Int32, Int32)] = []
        for file in files {
            offsets.append((Int32(blob.count), Int32(file.contents.count)))
            blob.append(file.contents)
        }

        for (index, file) in files.enumerated() {
            header.appendLengthPrefixed(file.path)
            header.appendInt32(offsets[index].0)
            header.appendInt32(offsets[index].1)
            for _ in 0 ..< trailingInt32Count { header.appendInt32(0) }
        }

        return header + blob
    }
}

extension Data {
    mutating func appendInt32(_ value: Int32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendFloat(_ value: Float) {
        Swift.withUnsafeBytes(of: value.bitPattern.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLengthPrefixed(_ string: String) {
        let bytes = Data(string.utf8)
        appendInt32(Int32(bytes.count))
        append(bytes)
    }

    /// Magic strings in the `.tex` format are fixed-width and null-terminated, unlike the
    /// length-prefixed strings used in `.pkg` headers.
    mutating func appendMagic(_ string: String) {
        append(Data(string.utf8))
        append(0)
    }
}
