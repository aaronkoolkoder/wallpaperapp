import AppKit
import CoreGraphics
import QuartzCore
import os

/// One wallpaper surface, bound to one display.
///
/// The window sits one level below the desktop icon layer, which places it above the system
/// desktop picture but below icons — icons must stay on top and stay clickable. It ignores mouse
/// events entirely, so right-click-on-desktop, drag-select, and Stage Manager all behave exactly
/// as they do with no wallpaper app installed. No private API, no accessibility permission, no
/// event tap.
@MainActor
public final class DesktopSurface {
    public let displayID: CGDirectDisplayID
    public private(set) var screen: NSScreen

    /// Called on the main actor once per display-link tick, only while running.
    public var onFrame: ((CFTimeInterval) -> Void)?
    /// Called when the surface's drawable size changes.
    public var onDrawableSizeChange: ((CGSize) -> Void)?
    /// Called when the window's occlusion state flips, which feeds ``PowerPolicy``.
    public var onOcclusionChange: ((Bool) -> Void)?

    public private(set) var directive: RenderDirective = .suspended(reason: .noContent)

    /// Whether this surface needs a display link at all.
    ///
    /// False for content that drives its own frames — `AVPlayerLayer` schedules from the video's
    /// own timebase, `WKWebView` from requestAnimationFrame, a still image never. Running a link
    /// for those wakes the process at the frame rate to call a callback that does nothing, which
    /// is exactly the kind of idle cost this project exists to avoid.
    public var needsDisplayLink: Bool = true {
        didSet {
            guard needsDisplayLink != oldValue else { return }
            if needsDisplayLink, case .running(let fps) = directive {
                startDisplayLink(fps: fps)
            } else if !needsDisplayLink {
                stopDisplayLink()
            }
        }
    }

    /// The Metal layer, if a Metal backend is currently mounted.
    public var metalLayer: CAMetalLayer? { (window.contentView as? MetalLayerView)?.metalLayer }
    public var isOccluded: Bool { !window.occlusionState.contains(.visible) }

    private let window: NSWindow
    /// The view the display link is attached to. Always the current content view.
    private var view: NSView
    private var displayLink: CADisplayLink?
    private var occlusionObserver: (any NSObjectProtocol)?
    private let log = Logger(subsystem: "app.diorama", category: "surface")

    public init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.screen = screen
        self.displayID = displayID

        view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )

        // One below the icon layer: above the system desktop picture, below the icons.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        // Present on every Space, and do not slide with Spaces transitions — the wallpaper is
        // part of the desktop, not a window that travels.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.displaysWhenScreenProfileChanges = true
        // Never let this window take focus or appear in window cycling.
        window.canHide = false
        view.wantsLayer = true
        window.contentView = view

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let occluded = self.isOccluded
                self.log.debug("display \(self.displayID) occluded=\(occluded)")
                self.onOcclusionChange?(occluded)
            }
        }
    }

    /// The window server's id for this surface, so a diagnostic can capture exactly this
    /// window and nothing else on the user's screen.
    public var windowNumber: Int { window.windowNumber }

    public func show() {
        window.orderFrontRegardless()
    }

    /// Re-bind to a moved or resized display. Called on screen-parameter changes.
    public func update(screen: NSScreen) {
        self.screen = screen
        window.setFrame(screen.frame, display: true)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)

        // Rebuilt rather than kept: the link is bound to the display the view was on, and a
        // display that has just been reconfigured — a lid opened, a monitor woken, a
        // resolution changed — is not necessarily the one it was bound to. A link left over
        // from the old configuration stops calling back, and nothing else would ever notice:
        // the wallpaper keeps its last frame and looks like a wallpaper that does not animate.
        if case .running(let fps) = directive, needsDisplayLink {
            stopDisplayLink()
            startDisplayLink(fps: fps)
        }
    }

    public func setResolutionScale(_ scale: Double) {
        resolutionScale = scale
        (view as? MetalLayerView)?.resolutionScale = scale
    }

    private var resolutionScale: Double = 1.0

    // MARK: - Content mounting
    //
    // Backends differ in what they need to put on screen: scenes want a CAMetalLayer, web
    // wallpapers want a live WKWebView, and video wants an AVSampleBufferDisplayLayer. Rather
    // than force everything through Metal, the surface hosts whatever view a backend supplies
    // and re-points the display link at it.

    /// Mount a Metal-backed view and return its layer. Idempotent.
    @discardableResult
    /// - Parameter device: the GPU the renderer will draw with. It must be the same one the
    ///   layer vends drawables from, and a layer with no device vends none at all.
    public func mountMetalLayer(device: (any MTLDevice)? = nil) -> CAMetalLayer? {
        if let existing = view as? MetalLayerView {
            if let device { existing.metalDevice = device }
            return existing.metalLayer
        }

        let metalView = MetalLayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        metalView.metalDevice = device ?? MTLCreateSystemDefaultDevice()
        metalView.resolutionScale = resolutionScale
        metalView.onDrawableSizeChange = { [weak self] size in self?.onDrawableSizeChange?(size) }
        mount(metalView)
        // Only after mounting, which is what gives the view a window to take a scale factor
        // from. Without this the caller's first render can find a zero-sized drawable.
        metalView.prepareDrawable()
        // Commit the layer tree before anyone asks it for a drawable. A `CAMetalLayer` that has
        // only just been made a window's content layer has not been through a transaction yet,
        // and `nextDrawable()` on one returns nil — which silently drops the caller's first
        // frame.
        CATransaction.flush()
        return metalView.metalLayer
    }

    /// Mount an arbitrary view as the surface's content, replacing whatever was there.
    public func mount(_ newView: NSView) {
        let wasRunning = !directive.isSuspended
        stopDisplayLink()

        newView.frame = NSRect(origin: .zero, size: screen.frame.size)
        newView.autoresizingMask = [.width, .height]
        view = newView
        window.contentView = newView

        // The display link is bound to a specific view, so swapping content requires rebuilding
        // it against the new one.
        if wasRunning, needsDisplayLink, case .running(let fps) = directive {
            startDisplayLink(fps: fps)
        }
    }

    /// Drop whatever is mounted and go back to an empty black surface.
    public func unmountContent() {
        stopDisplayLink()
        let empty = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        empty.wantsLayer = true
        empty.layer?.backgroundColor = .black
        view = empty
        window.contentView = empty
    }

    /// Apply a policy decision. Starting and stopping the display link — rather than simply
    /// skipping work inside the callback — is what lets the process actually go idle.
    public func apply(_ directive: RenderDirective) {
        guard directive != self.directive else { return }
        self.directive = directive

        switch directive {
        case .suspended(let reason):
            stopDisplayLink()
            log.info("display \(self.displayID) suspended: \(reason.rawValue, privacy: .public)")
        case .running(let fps):
            if needsDisplayLink {
                startDisplayLink(fps: fps)
                log.info("display \(self.displayID) running at \(fps)fps")
            } else {
                log.info("display \(self.displayID) running, content self-driven")
            }
        }
    }

    public func tearDown() {
        stopDisplayLink()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        window.contentView = nil
        window.close()
    }

    // MARK: - Display link

    private func startDisplayLink(fps: Int) {
        if displayLink == nil {
            // `NSView.displayLink(target:selector:)` binds the link to the display the view is
            // actually on and follows the view if it moves between displays — which matters on a
            // mixed 60Hz/ProMotion setup where a single global link would be wrong for one of them.
            let link = view.displayLink(target: self, selector: #selector(handleFrame(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        // A range rather than a fixed value lets the system pick an efficient cadence; the
        // maximum is what actually caps us.
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(max(1, fps / 2)), maximum: Float(fps), preferred: Float(fps)
        )
        displayLink?.isPaused = false
    }

    private func stopDisplayLink() {
        displayLink?.isPaused = true
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleFrame(_ link: CADisplayLink) {
        onFrame?(link.targetTimestamp)
    }
}
