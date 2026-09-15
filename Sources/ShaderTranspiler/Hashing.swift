import CryptoKit
import Foundation

/// Content hashing for cache keys and for shortening long variant keys.
///
/// SHA-256 via CryptoKit: system-provided, no third-party licensing surface (PLAN.md §11).
enum ShaderHashing {
    static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
