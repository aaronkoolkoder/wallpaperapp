import Foundation
import Testing
@testable import WallpaperKit

/// The power policy is the load-bearing performance claim of this project, so it is tested as a
/// pure function across the whole precedence ladder rather than exercised incidentally.
@Suite("PowerPolicy")
struct PowerPolicyTests {

    /// A display that is visible, powered, and has something to show.
    private func healthy() -> (SystemState, DisplayConditions) {
        var system = SystemState()
        system.isOnACPower = true
        system.batteryPercent = 100
        system.isLowPowerMode = false
        system.thermalState = .nominal

        var display = DisplayConditions()
        display.hasContent = true
        display.isOccluded = false
        display.isCoveredByFullscreenApp = false
        return (system, display)
    }

    private func evaluate(
        _ system: SystemState,
        _ display: DisplayConditions,
        _ preferences: PowerPreferences = .default,
        paused: Bool = false
    ) -> RenderDirective {
        PowerPolicy.evaluate(
            system: system, display: display, preferences: preferences, isUserPaused: paused
        )
    }

    // MARK: - The happy path

    @Test("Renders at the AC frame rate when everything is normal")
    func rendersWhenHealthy() {
        let (system, display) = healthy()
        #expect(evaluate(system, display) == .running(fps: PowerPreferences.default.frameRateOnAC))
    }

    @Test("Drops to the battery frame rate on battery")
    func batteryRate() {
        var (system, display) = healthy()
        system.isOnACPower = false
        #expect(evaluate(system, display) == .running(fps: PowerPreferences.default.frameRateOnBattery))
        _ = display
    }

    // MARK: - Suspension, the whole point

    @Test("Occlusion suspends — the single most important case")
    func occlusionSuspends() {
        var (system, display) = healthy()
        display.isOccluded = true
        #expect(evaluate(system, display) == .suspended(reason: .occluded))
        _ = system
    }

    @Test("A fullscreen app suspends that display")
    func fullscreenSuspends() {
        var (system, display) = healthy()
        display.isCoveredByFullscreenApp = true
        #expect(evaluate(system, display) == .suspended(reason: .fullscreenApp))
        _ = system
    }

    @Test("No assigned wallpaper means no work at all")
    func noContentSuspends() {
        var (system, display) = healthy()
        display.hasContent = false
        #expect(evaluate(system, display) == .suspended(reason: .noContent))
        _ = system
    }

    @Test("System sleep suspends")
    func systemAsleepSuspends() {
        var (system, display) = healthy()
        system.isSystemAsleep = true
        #expect(evaluate(system, display) == .suspended(reason: .systemAsleep))
        _ = display
    }

    @Test("Display sleep suspends")
    func displaysAsleepSuspends() {
        var (system, display) = healthy()
        system.areDisplaysAsleep = true
        #expect(evaluate(system, display) == .suspended(reason: .displayAsleep))
        _ = display
    }

    @Test("A locked screen suspends")
    func screenLockedSuspends() {
        var (system, display) = healthy()
        system.isScreenLocked = true
        #expect(evaluate(system, display) == .suspended(reason: .screenLocked))
        _ = display
    }

    @Test("Fast user switching suspends")
    func inactiveSessionSuspends() {
        var (system, display) = healthy()
        system.isSessionActive = false
        #expect(evaluate(system, display) == .suspended(reason: .sessionInactive))
        _ = display
    }

    @Test("Critical thermal state suspends")
    func thermalCriticalSuspends() {
        var (system, display) = healthy()
        system.thermalState = .critical
        #expect(evaluate(system, display) == .suspended(reason: .thermalCritical))
        _ = display
    }

    @Test("Serious thermal state halves the rate rather than stopping")
    func thermalSeriousThrottles() {
        var (system, display) = healthy()
        system.thermalState = .serious
        let expected = max(10, PowerPreferences.default.frameRateOnAC / 2)
        #expect(evaluate(system, display) == .running(fps: expected))
        _ = display
    }

    @Test("Low Power Mode suspends by default")
    func lowPowerSuspendsByDefault() {
        var (system, display) = healthy()
        system.isLowPowerMode = true
        #expect(evaluate(system, display) == .suspended(reason: .lowPowerMode))
        _ = display
    }

    @Test("Low Power Mode throttles instead when the user opts out of suspending")
    func lowPowerThrottlesWhenOptedOut() {
        var (system, display) = healthy()
        system.isLowPowerMode = true
        var preferences = PowerPreferences.default
        preferences.suspendInLowPowerMode = false
        #expect(evaluate(system, display, preferences) == .running(fps: preferences.frameRateLowPower))
        _ = display
    }

    @Test("Battery below the floor suspends")
    func batteryFloorSuspends() {
        var (system, display) = healthy()
        system.isOnACPower = false
        system.batteryPercent = 15
        #expect(evaluate(system, display) == .suspended(reason: .batteryLow))
        _ = display
    }

    @Test("A low battery on wall power does not suspend — it is charging")
    func lowBatteryOnACStillRenders() {
        var (system, display) = healthy()
        system.isOnACPower = true
        system.batteryPercent = 5
        #expect(evaluate(system, display).isSuspended == false)
        _ = display
    }

    @Test("A desktop with no battery reading is never suspended for battery")
    func missingBatteryReadingDoesNotSuspend() {
        var (system, display) = healthy()
        system.isOnACPower = false
        system.batteryPercent = nil
        #expect(evaluate(system, display).isSuspended == false)
        _ = display
    }

    // MARK: - Precedence

    @Test("User pause outranks every automatic condition")
    func userPauseWins() {
        var (system, display) = healthy()
        display.isOccluded = true
        system.isLowPowerMode = true
        #expect(evaluate(system, display, paused: true) == .suspended(reason: .userPaused))
    }

    @Test("A more fundamental reason is reported over a shallower one")
    func systemAsleepOutranksOcclusion() {
        var (system, display) = healthy()
        system.isSystemAsleep = true
        display.isOccluded = true
        #expect(evaluate(system, display) == .suspended(reason: .systemAsleep))
    }

    @Test("Having nothing to draw outranks even a user pause")
    func noContentOutranksPause() {
        var (system, display) = healthy()
        display.hasContent = false
        #expect(evaluate(system, display, paused: true) == .suspended(reason: .noContent))
        _ = system
    }

    // MARK: - Frame rate clamping

    @Test("Never renders faster than the content asks for")
    func contentRateClamps() {
        var (system, display) = healthy()
        display.contentFrameRate = 12
        #expect(evaluate(system, display) == .running(fps: 12))
        _ = system
    }

    @Test("A content rate above our cap does not raise the cap")
    func contentRateDoesNotRaiseCap() {
        var (system, display) = healthy()
        display.contentFrameRate = 240
        #expect(evaluate(system, display) == .running(fps: PowerPreferences.default.frameRateOnAC))
        _ = system
    }

    @Test("Frame rate never reaches zero while running")
    func rateNeverZero() {
        var (system, display) = healthy()
        display.contentFrameRate = 0
        var preferences = PowerPreferences.default
        preferences.frameRateOnAC = 0
        let directive = evaluate(system, display, preferences)
        #expect(directive.frameRate >= 1)
        _ = system
    }

    @Test("Suspension reports a zero frame rate")
    func suspendedRateIsZero() {
        #expect(RenderDirective.suspended(reason: .occluded).frameRate == 0)
    }

    // MARK: - Turning occlusion suspension off

    @Test("Occlusion can be disabled for diagnostics")
    func occlusionSuspensionIsOptional() {
        var (system, display) = healthy()
        display.isOccluded = true
        var preferences = PowerPreferences.default
        preferences.suspendWhenOccluded = false
        #expect(evaluate(system, display, preferences).isSuspended == false)
        _ = system
    }

    // MARK: - Choices the user makes in Settings

    @Test("Another app in front stops the wallpaper only when the user asked for that")
    func anotherAppActive() {
        var (system, display) = healthy()
        system.isAnotherAppActive = true
        #expect(evaluate(system, display).isSuspended == false)

        var preferences = PowerPreferences.default
        preferences.suspendWhenAnotherAppIsActive = true
        #expect(evaluate(system, display, preferences) == .suspended(reason: .anotherAppActive))

        system.isAnotherAppActive = false
        #expect(evaluate(system, display, preferences).isSuspended == false)
    }

    @Test("Covered still reads as covered when another app is also in front")
    func occlusionOutranksAnotherApp() {
        var (system, display) = healthy()
        system.isAnotherAppActive = true
        display.isOccluded = true
        var preferences = PowerPreferences.default
        preferences.suspendWhenAnotherAppIsActive = true
        #expect(evaluate(system, display, preferences) == .suspended(reason: .occluded))
    }

    @Test("Battery stops the wallpaper only when asked, and only off wall power")
    func stopOnBattery() {
        var (system, display) = healthy()
        var preferences = PowerPreferences.default
        preferences.suspendOnBattery = true
        #expect(evaluate(system, display, preferences).isSuspended == false)

        system.isOnACPower = false
        system.batteryPercent = 90
        #expect(evaluate(system, display, preferences) == .suspended(reason: .onBattery))
        #expect(evaluate(system, display).isSuspended == false)
    }

    @Test("Finder and nothing count as the desktop; any other app does not")
    func whatCountsAsAnotherApp() {
        #expect(SystemPowerMonitor.isAnotherApp("com.apple.finder") == false)
        #expect(SystemPowerMonitor.isAnotherApp(nil) == false)
        #expect(SystemPowerMonitor.isAnotherApp("com.apple.Safari"))
        #expect(SystemPowerMonitor.isAnotherApp("com.microsoft.VSCode"))
    }

    @Test("Saved preferences round-trip, and an older save keeps its values for new options' defaults")
    func preferencesCoding() throws {
        var preferences = PowerPreferences.default
        preferences.suspendUnderFullscreenApps = false
        preferences.suspendWhenAnotherAppIsActive = true
        preferences.frameRateOnAC = 60
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(PowerPreferences.self, from: data) == preferences)

        // Written before the newer options existed.
        let older = Data(#"{"frameRateOnAC": 60, "suspendUnderFullscreenApps": false}"#.utf8)
        let decoded = try JSONDecoder().decode(PowerPreferences.self, from: older)
        #expect(decoded.frameRateOnAC == 60)
        #expect(decoded.suspendUnderFullscreenApps == false)
        #expect(decoded.suspendWhenAnotherAppIsActive == PowerPreferences.default.suspendWhenAnotherAppIsActive)
        #expect(decoded.frameRateOnBattery == PowerPreferences.default.frameRateOnBattery)
    }

    /// Uncovering the desktop has to start it again, and the coordinator has to notice.
    ///
    /// The policy half is this. The other half is that something feeds it a fresh reading:
    /// occlusion arrives as a notification, and a missed one is the only condition whose
    /// failure is unrecoverable — the wallpaper sits on its last frame for as long as the
    /// wallpaper is set, which is indistinguishable from a wallpaper that does not animate.
    /// The coordinator therefore re-reads occlusion on its slow poll as well.
    @Test("A wallpaper suspended for being covered runs again when it is uncovered")
    func uncoveringResumes() {
        var display = DisplayConditions()
        display.hasContent = true
        display.isOccluded = true
        let system = SystemState()

        #expect(evaluate(system, display) == .suspended(reason: .occluded))

        display.isOccluded = false
        #expect(evaluate(system, display) == .running(fps: 30))
    }
}
