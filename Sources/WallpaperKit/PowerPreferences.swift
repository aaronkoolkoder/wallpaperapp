import Foundation

/// User-tunable inputs to ``PowerPolicy``.
///
/// Defaults are deliberately conservative. A wallpaper runs 24/7 in the background, so the
/// cost of a bad default is paid continuously and silently — the user notices it as "my
/// battery got worse since I installed that app" and uninstalls without filing a bug.
public struct PowerPreferences: Equatable, Sendable, Codable {
    /// Frame cap while on wall power.
    public var frameRateOnAC: Int
    /// Frame cap while on battery. Lower by default; most people cannot tell 30 from 60 on a
    /// background image they are not looking at.
    public var frameRateOnBattery: Int
    /// Frame cap under Low Power Mode, if `suspendInLowPowerMode` is off.
    public var frameRateLowPower: Int
    /// Suspend outright in Low Power Mode. On by default: the user has explicitly told the OS
    /// they want battery preserved, and a decorative background is the easiest thing to give up.
    public var suspendInLowPowerMode: Bool
    /// Suspend when battery drops below this percentage. 0 disables.
    public var batteryFloorPercent: Int
    /// Stop when the surface is fully covered. Effectively never turn this off; it is exposed
    /// only for diagnostics.
    public var suspendWhenOccluded: Bool
    /// Stop the display that a fullscreen app owns.
    public var suspendUnderFullscreenApps: Bool
    /// Stop whenever an app other than the desktop is in front — play only while you are
    /// looking at the desktop. Off by default: most people want the wallpaper alive behind
    /// their windows, and occlusion already stops it when those windows cover it.
    public var suspendWhenAnotherAppIsActive: Bool = false
    /// Stop whenever the Mac is running on battery.
    public var suspendOnBattery: Bool = false
    /// Reduce frame rate one step at `.serious` thermal pressure, suspend at `.critical`.
    public var respectThermalPressure: Bool
    /// Render at a fraction of native resolution and upscale. See PLAN.md §6.2 — on a 5K
    /// display this is a large GPU saving for an element nobody inspects at 1:1.
    public var resolutionScale: Double

    public static let `default` = PowerPreferences(
        frameRateOnAC: 30,
        frameRateOnBattery: 24,
        frameRateLowPower: 15,
        suspendInLowPowerMode: true,
        batteryFloorPercent: 20,
        suspendWhenOccluded: true,
        suspendUnderFullscreenApps: true,
        respectThermalPressure: true,
        resolutionScale: 0.75
    )

    /// Uncapped-ish profile for users who explicitly want smoothness over battery.
    public static let performance = PowerPreferences(
        frameRateOnAC: 60,
        frameRateOnBattery: 30,
        frameRateLowPower: 15,
        suspendInLowPowerMode: true,
        batteryFloorPercent: 10,
        suspendWhenOccluded: true,
        suspendUnderFullscreenApps: true,
        respectThermalPressure: true,
        resolutionScale: 1.0
    )

    public init(
        frameRateOnAC: Int, frameRateOnBattery: Int, frameRateLowPower: Int,
        suspendInLowPowerMode: Bool, batteryFloorPercent: Int, suspendWhenOccluded: Bool,
        suspendUnderFullscreenApps: Bool, respectThermalPressure: Bool, resolutionScale: Double,
        suspendWhenAnotherAppIsActive: Bool = false, suspendOnBattery: Bool = false
    ) {
        self.frameRateOnAC = frameRateOnAC
        self.frameRateOnBattery = frameRateOnBattery
        self.frameRateLowPower = frameRateLowPower
        self.suspendInLowPowerMode = suspendInLowPowerMode
        self.batteryFloorPercent = batteryFloorPercent
        self.suspendWhenOccluded = suspendWhenOccluded
        self.suspendUnderFullscreenApps = suspendUnderFullscreenApps
        self.respectThermalPressure = respectThermalPressure
        self.resolutionScale = resolutionScale
        self.suspendWhenAnotherAppIsActive = suspendWhenAnotherAppIsActive
        self.suspendOnBattery = suspendOnBattery
    }

    // Decoded field by field over the defaults, so settings saved by an older build — which
    // lack whatever was added since — still load, and a new option starts at its default
    // rather than discarding everything the user had set.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var value = Self.default
        func read<T: Decodable>(_ key: CodingKeys, into field: inout T) {
            if let decoded = try? container.decodeIfPresent(T.self, forKey: key) { field = decoded }
        }
        read(.frameRateOnAC, into: &value.frameRateOnAC)
        read(.frameRateOnBattery, into: &value.frameRateOnBattery)
        read(.frameRateLowPower, into: &value.frameRateLowPower)
        read(.suspendInLowPowerMode, into: &value.suspendInLowPowerMode)
        read(.batteryFloorPercent, into: &value.batteryFloorPercent)
        read(.suspendWhenOccluded, into: &value.suspendWhenOccluded)
        read(.suspendUnderFullscreenApps, into: &value.suspendUnderFullscreenApps)
        read(.respectThermalPressure, into: &value.respectThermalPressure)
        read(.resolutionScale, into: &value.resolutionScale)
        read(.suspendWhenAnotherAppIsActive, into: &value.suspendWhenAnotherAppIsActive)
        read(.suspendOnBattery, into: &value.suspendOnBattery)
        self = value
    }
}
