import Foundation

/// What a surface should actually be doing right now.
///
/// This is the output of ``PowerPolicy`` and the single input that decides whether a display
/// link ticks. The performance target in PLAN.md §6 is met almost entirely by returning
/// ``suspended`` aggressively rather than by making rendering faster — a wallpaper is invisible
/// most of the time it exists, and rendering an invisible wallpaper is pure waste.
public enum RenderDirective: Equatable, Sendable {
    /// Stop entirely. No display link tick, no command buffer, no GPU work.
    ///
    /// Distinct from a very low frame rate: suspension releases the display link so the
    /// process can go fully idle and the CPU can enter a deeper sleep state.
    case suspended(reason: SuspensionReason)

    /// Render, capped at this rate. Never exceeds the wallpaper's own declared frame rate.
    case running(fps: Int)

    public var isSuspended: Bool {
        if case .suspended = self { return true }
        return false
    }

    public var frameRate: Int {
        switch self {
        case .suspended: 0
        case .running(let fps): fps
        }
    }
}

/// Why rendering stopped. Surfaced in the diagnostics HUD so the behaviour is legible rather
/// than looking like a bug — "my wallpaper froze" is otherwise a support burden.
public enum SuspensionReason: String, Equatable, Sendable, CustomStringConvertible {
    /// Every pixel of the surface is behind another window. The common case by far.
    case occluded
    /// A fullscreen application owns this display.
    case fullscreenApp
    /// The display is asleep.
    case displayAsleep
    /// The machine is asleep.
    case systemAsleep
    /// The screen is locked.
    case screenLocked
    /// Another user session is active (fast user switching).
    case sessionInactive
    /// Low Power Mode is on and the user has not opted to keep rendering.
    case lowPowerMode
    /// Thermal pressure is critical.
    case thermalCritical
    /// Battery below the configured floor.
    case batteryLow
    /// The user pressed pause.
    case userPaused
    /// Another app is in front, and the user asked for the wallpaper to stop then.
    case anotherAppActive
    /// Running on battery, and the user asked for the wallpaper to stop then.
    case onBattery
    /// No wallpaper is assigned to this display.
    case noContent

    public var description: String {
        switch self {
        case .occluded: "Covered by a window"
        case .fullscreenApp: "A fullscreen app is in front"
        case .displayAsleep: "Display asleep"
        case .systemAsleep: "System asleep"
        case .screenLocked: "Screen locked"
        case .sessionInactive: "Another user is active"
        case .lowPowerMode: "Low Power Mode"
        case .thermalCritical: "Mac is too warm"
        case .batteryLow: "Battery low"
        case .userPaused: "Paused"
        case .anotherAppActive: "Another app is in use"
        case .onBattery: "On battery"
        case .noContent: "No wallpaper set"
        }
    }
}
