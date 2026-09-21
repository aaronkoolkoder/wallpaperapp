import CoreGraphics
import Foundation
import LibraryKit

/// Which wallpaper was on which display, so the next launch puts them back.
///
/// Without this, "open Diorama at login" starts the app to a blank desktop: the wallpaper only
/// appears once the user opens the library and clicks something, which is not what asking an
/// app to run in the background means.
@MainActor
public final class WallpaperSessionStore {
    private static let key = "app.diorama.session"

    private let defaults: any PreferenceStorage
    private var assignments: [String: String]

    public init(defaults: any PreferenceStorage = UserDefaults.standard) {
        self.defaults = defaults
        // A session that will not decode is not worth refusing to launch over; the cost of
        // starting empty is one click.
        self.assignments = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// A key that survives a reboot.
    ///
    /// `CGDirectDisplayID` does not: the window server hands them out per session, so storing
    /// one would restore the wallpaper onto whichever display happened to inherit the number.
    /// Vendor, model and serial identify the panel itself.
    public static func key(for display: CGDirectDisplayID) -> String {
        // Explicitly 1: `CGDisplayIsBuiltin` answers -1 for a display it cannot resolve, so
        // testing against 0 files every unknown display under the built-in panel's wallpaper.
        if CGDisplayIsBuiltin(display) == 1 { return "builtin" }

        let identity = [
            CGDisplayVendorNumber(display),
            CGDisplayModelNumber(display),
            CGDisplaySerialNumber(display),
        ]
        // Panels that report nothing, and ids that resolve to no panel at all, both come back
        // as all-zero or all-`UInt32.max`. Falling back to the session's own id means the
        // assignment will not survive a reboot, which is better than every such display
        // sharing one entry and overwriting each other's wallpaper.
        let unknown = identity.allSatisfy { $0 == 0 || $0 == UInt32.max }
        guard !unknown else { return "display-\(display)" }
        return identity.map(String.init).joined(separator: "-")
    }

    public func remember(_ wallpaperID: String, on display: CGDirectDisplayID) {
        assignments[Self.key(for: display)] = wallpaperID
        save()
    }

    public func forget(_ display: CGDirectDisplayID) {
        assignments.removeValue(forKey: Self.key(for: display))
        save()
    }

    /// What was playing on `display` when the app last ran, if anything.
    public func wallpaperID(for display: CGDirectDisplayID) -> String? {
        assignments[Self.key(for: display)]
    }

    /// The single most recent assignment, whatever display it was on.
    ///
    /// A laptop that was last used with an external monitor attached, and is now not, should
    /// still come back to the wallpaper the user chose rather than to nothing.
    public var anyWallpaperID: String? { assignments.values.first }

    public var isEmpty: Bool { assignments.isEmpty }

    public func clear() {
        assignments.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(assignments) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
