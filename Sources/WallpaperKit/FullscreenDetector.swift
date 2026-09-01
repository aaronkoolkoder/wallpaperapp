import AppKit
import CoreGraphics
import Foundation

/// Detects whether a display is entirely covered by an ordinary application window.
///
/// This exists as a *supplement* to `NSWindow.occlusionState`, which is the primary and much
/// cheaper signal. Occlusion state is authoritative when it fires, but there are cases — notably
/// a native-fullscreen app that has moved to its own Space — where our desktop-level window is
/// not reported as occluded even though nothing we draw can possibly be seen.
///
/// Deliberately uses only window *geometry*, never window names or owner names: reading those
/// from `CGWindowListCopyWindowInfo` requires the Screen Recording permission, and this app's
/// pitch is that it asks for almost nothing (PLAN.md §7.3).
public enum FullscreenDetector {
    /// Screen-space coverage test, in Core Graphics' flipped global coordinates.
    ///
    /// - Parameter screen: the display to test.
    /// - Returns: `true` if a normal-layer window covers essentially the whole display.
    public static func isDisplayCovered(_ screen: NSScreen) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let target = flippedFrame(of: screen)
        // A few points of slack: fullscreen windows are sometimes reported a pixel shy, and
        // demanding an exact match makes this silently never fire.
        let tolerance: CGFloat = 2

        for window in windows {
            // Layer 0 is the normal application layer. Anything above (panels, menu bar,
            // status items) is not what we mean by "covered", and anything below is desktop
            // furniture — including our own surfaces, which must never count.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            if bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(target) { return true }
        }
        return false
    }

    /// `NSScreen.frame` is bottom-left origin relative to the primary display; the window list
    /// is top-left origin. Converting one to the other is the entire subtlety of this file, and
    /// getting it wrong produces a detector that works on single-display Macs and fails on
    /// multi-display setups with a screen above or below the primary.
    private static func flippedFrame(of screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return screen.frame }
        let primaryHeight = primary.frame.maxY
        let frame = screen.frame
        return CGRect(
            x: frame.origin.x,
            y: primaryHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}
