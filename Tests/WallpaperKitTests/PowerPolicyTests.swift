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
}
