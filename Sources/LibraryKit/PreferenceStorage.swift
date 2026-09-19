import Foundation

/// The slice of `UserDefaults` the app's stores actually use.
///
/// Injected rather than taken directly so tests can run against memory. A test that points a
/// store at a real `UserDefaults` suite writes a plist into the user's home directory, and
/// deleting it afterwards races with `cfprefsd` writing it back — which left dozens of stray
/// `app.diorama.tests.*.plist` files behind before this existed. There is no way to ask for a
/// throwaway `UserDefaults` that never touches disk, so the dependency is inverted instead.
public protocol PreferenceStorage: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

/// `UserDefaults` already has exactly this shape, so the conformance needs no body.
extension UserDefaults: PreferenceStorage {}

/// Storage that lives and dies with the object holding it.
///
/// For tests and SwiftUI previews: nothing reaches disk, nothing outlives the process, and two
/// instances cannot see each other's writes.
public final class InMemoryPreferences: PreferenceStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public init() {}

    public func data(forKey defaultName: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[defaultName] as? Data
    }

    /// Matches `UserDefaults`: an unset key reads as false rather than as missing.
    public func bool(forKey defaultName: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values[defaultName] as? Bool ?? false
    }

    public func set(_ value: Any?, forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
    }

    public func removeObject(forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: defaultName)
    }
}
