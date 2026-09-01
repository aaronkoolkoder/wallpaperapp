import AppKit
import Foundation
import IOKit.ps
import os

/// A snapshot of everything about the machine that should influence whether we render.
public struct SystemState: Equatable, Sendable {
    public var isOnACPower: Bool = true
    public var batteryPercent: Int? = nil
    public var isLowPowerMode: Bool = false
    public var thermalState: ProcessInfo.ThermalState = .nominal
    public var isSystemAsleep: Bool = false
    public var areDisplaysAsleep: Bool = false
    public var isScreenLocked: Bool = false
    public var isSessionActive: Bool = true

    public init() {}
}

/// Observes the OS signals that gate rendering, and republishes them as a single ``SystemState``.
///
/// Everything here is a notification subscription rather than a poll. Polling for power state
/// on a background app is itself a measurable battery cost, which would be a self-defeating way
/// to implement a power saver. The one exception is the power-source read, which has no usable
/// push API for the *percentage* and so is refreshed on the IOKit change notification only.
@MainActor
public final class SystemPowerMonitor {
    public private(set) var state = SystemState() {
        didSet { if state != oldValue { onChange?(state) } }
    }

    /// Called on the main actor whenever any observed value actually changes.
    public var onChange: ((SystemState) -> Void)?

    private let log = Logger(subsystem: "app.diorama", category: "power")
    private var observers: [any NSObjectProtocol] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?

    public init() {}

    public func start() {
        refreshPowerSource()
        state.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        state.thermalState = ProcessInfo.processInfo.thermalState

        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()

        func observe(
            _ name: Notification.Name,
            on nc: NotificationCenter,
            _ handler: @escaping @MainActor (SystemPowerMonitor) -> Void
        ) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            })
        }

        observe(ProcessInfo.thermalStateDidChangeNotification, on: center) {
            $0.state.thermalState = ProcessInfo.processInfo.thermalState
            $0.log.info("thermal state -> \($0.state.thermalState.label, privacy: .public)")
        }
        observe(.NSProcessInfoPowerStateDidChange, on: center) {
            $0.state.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            $0.refreshPowerSource()
        }

        observe(NSWorkspace.willSleepNotification, on: workspace) { $0.state.isSystemAsleep = true }
        observe(NSWorkspace.didWakeNotification, on: workspace) { $0.state.isSystemAsleep = false }
        observe(NSWorkspace.screensDidSleepNotification, on: workspace) { $0.state.areDisplaysAsleep = true }
        observe(NSWorkspace.screensDidWakeNotification, on: workspace) { $0.state.areDisplaysAsleep = false }
        observe(NSWorkspace.sessionDidResignActiveNotification, on: workspace) { $0.state.isSessionActive = false }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, on: workspace) { $0.state.isSessionActive = true }

        // Screen lock has no public AppKit notification; the distributed one is the documented
        // path used by every Mac app that needs it.
        observers.append(distributed.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.isScreenLocked = true }
        })
        observers.append(distributed.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.isScreenLocked = false }
        })

        startPowerSourceNotifications()
        log.info("monitor started: \(String(describing: self.state), privacy: .public)")
    }

    public func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = nil
        }
    }

    // No `deinit` cleanup: the run-loop source is main-actor state and a nonisolated deinit
    // cannot legally touch it under strict concurrency. `stop()` is the supported teardown, and
    // this object is owned for the lifetime of the app anyway.

    // MARK: - Power source

    /// IOKit posts a bare "something changed" callback with no payload, so the run-loop source
    /// only triggers a re-read rather than carrying state itself.
    private func startPowerSourceNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<SystemPowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refreshPowerSource() }
        }, context)?.takeRetainedValue() else {
            log.warning("could not create power source notification; battery state will be stale")
            return
        }
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func refreshPowerSource() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            // Desktops with no battery legitimately return nothing. Treat as wall power.
            state.isOnACPower = true
            state.batteryPercent = nil
            return
        }

        if let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
            state.isOnACPower = (type == kIOPSACPowerValue)
        }

        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            state.batteryPercent = nil
            return
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            state.batteryPercent = Int((Double(current) / Double(max) * 100).rounded())
            return
        }
        state.batteryPercent = nil
    }
}

extension ProcessInfo.ThermalState {
    public var label: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
