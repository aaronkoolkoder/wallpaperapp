import AppKit
import CoreGraphics
import Foundation
import os

/// Per-display inputs that the policy cannot observe for itself.
public struct DisplayConditions: Equatable, Sendable {
    /// From `NSWindow.occlusionState`. The primary and cheapest suspension signal.
    public var isOccluded: Bool = false
    /// From ``FullscreenDetector``. Supplements occlusion for the cross-Space case.
    public var isCoveredByFullscreenApp: Bool = false
    /// False when no wallpaper is assigned to this display.
    public var hasContent: Bool = false
    /// The wallpaper's own declared frame rate. We never render faster than the content wants;
    /// a 24fps video does not benefit from a 60fps display link.
    public var contentFrameRate: Int? = nil

    public init() {}
}

/// Decides what each display should be doing, from system power state and per-display conditions.
///
/// The decision itself is ``evaluate(system:display:preferences:isUserPaused:)`` — a pure static
/// function with no dependencies on AppKit, IOKit, or any live system state. That is deliberate:
/// power behaviour is the load-bearing claim of this project (PLAN.md §6) and it needs to be
/// exhaustively unit-testable without a Mac in a particular power state.
@MainActor
public final class PowerPolicy {
    public var preferences: PowerPreferences {
        didSet { if preferences != oldValue { reevaluateAll() } }
    }
    public var isUserPaused: Bool = false {
        didSet { if isUserPaused != oldValue { reevaluateAll() } }
    }

    public private(set) var systemState = SystemState()
    private var conditions: [CGDirectDisplayID: DisplayConditions] = [:]
    private var lastDirectives: [CGDirectDisplayID: RenderDirective] = [:]
    private let log = Logger(subsystem: "app.diorama", category: "policy")

    /// Fired only when a display's directive actually changes, never on every input tick.
    public var onDirectiveChange: ((CGDirectDisplayID, RenderDirective) -> Void)?

    public init(preferences: PowerPreferences = .default) {
        self.preferences = preferences
    }

    public func systemStateChanged(_ state: SystemState) {
        systemState = state
        reevaluateAll()
    }

    public func updateConditions(_ update: DisplayConditions, for display: CGDirectDisplayID) {
        guard conditions[display] != update else { return }
        conditions[display] = update
        reevaluate(display)
    }

    public func removeDisplay(_ display: CGDirectDisplayID) {
        conditions.removeValue(forKey: display)
        lastDirectives.removeValue(forKey: display)
    }

    public func directive(for display: CGDirectDisplayID) -> RenderDirective {
        Self.evaluate(
            system: systemState,
            display: conditions[display] ?? DisplayConditions(),
            preferences: preferences,
            isUserPaused: isUserPaused
        )
    }

    public var allDisplays: [CGDirectDisplayID] { Array(conditions.keys) }

    private func reevaluateAll() {
        for display in conditions.keys { reevaluate(display) }
    }

    private func reevaluate(_ display: CGDirectDisplayID) {
        let directive = directive(for: display)
        guard lastDirectives[display] != directive else { return }
        lastDirectives[display] = directive
        log.debug("display \(display) -> \(String(describing: directive), privacy: .public)")
        onDirectiveChange?(display, directive)
    }

    // MARK: - The decision

    /// Pure decision function. Ordered as a precedence ladder, cheapest and most decisive first.
    ///
    /// Precedence matters: a machine that is asleep *and* occluded *and* in Low Power Mode should
    /// report the most fundamental reason, because the reason is user-visible in the diagnostics
    /// panel and "System asleep" is more useful than "Covered by a window".
    nonisolated public static func evaluate(
        system: SystemState,
        display: DisplayConditions,
        preferences: PowerPreferences,
        isUserPaused: Bool
    ) -> RenderDirective {
        // 1. Nothing to draw.
        if !display.hasContent { return .suspended(reason: .noContent) }

        // 2. Explicit user intent outranks everything automatic.
        if isUserPaused { return .suspended(reason: .userPaused) }

        // 3. The machine or its displays are not in a state where pixels reach a human.
        if system.isSystemAsleep { return .suspended(reason: .systemAsleep) }
        if system.areDisplaysAsleep { return .suspended(reason: .displayAsleep) }
        if system.isScreenLocked { return .suspended(reason: .screenLocked) }
        if !system.isSessionActive { return .suspended(reason: .sessionInactive) }

        // 4. Thermal emergency. Ignoring this makes us the reason someone's fans are loud.
        if preferences.respectThermalPressure, system.thermalState == .critical {
            return .suspended(reason: .thermalCritical)
        }

        // 5. Battery protection.
        if preferences.suspendInLowPowerMode, system.isLowPowerMode {
            return .suspended(reason: .lowPowerMode)
        }
        if !system.isOnACPower, preferences.batteryFloorPercent > 0,
           let percent = system.batteryPercent, percent <= preferences.batteryFloorPercent {
            return .suspended(reason: .batteryLow)
        }

        // 6. Nobody can see this display's wallpaper. The single biggest win in the whole system
        //    — on a normal desktop with any window open, this is the branch that is taken.
        if preferences.suspendWhenOccluded, display.isOccluded {
            return .suspended(reason: .occluded)
        }
        if preferences.suspendUnderFullscreenApps, display.isCoveredByFullscreenApp {
            return .suspended(reason: .fullscreenApp)
        }

        // 7. We are actually rendering. Pick a rate.
        var fps: Int
        if system.isLowPowerMode {
            fps = preferences.frameRateLowPower
        } else if system.isOnACPower {
            fps = preferences.frameRateOnAC
        } else {
            fps = preferences.frameRateOnBattery
        }

        // Step down one notch under sustained thermal pressure rather than stopping outright.
        if preferences.respectThermalPressure, system.thermalState == .serious {
            fps = max(10, fps / 2)
        }

        // Never exceed what the content itself asks for.
        if let contentRate = display.contentFrameRate, contentRate > 0 {
            fps = min(fps, contentRate)
        }

        return .running(fps: max(1, fps))
    }
}
