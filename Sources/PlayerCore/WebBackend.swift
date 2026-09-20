import AppKit
import Diagnostics
import Foundation
import SceneEngine
import WallpaperKit
import WebKit
import os

/// Plays HTML/JS wallpapers in a `WKWebView`.
///
/// Network access is blocked outright. Workshop web wallpapers are arbitrary third-party
/// HTML and JavaScript; allowing them to make requests would mean a decorative background could
/// silently phone home, and would quietly break this project's central claim that nothing leaves
/// the machine (PLAN.md §7.3). Anything a wallpaper needs must be in its own folder.
@MainActor
public final class WebBackend: NSObject, WallpaperBackend {
    public static let kind: WallpaperKind = .web
    public static let needsDisplayLink = false

    /// Web wallpapers drive their own animation through rAF, so there is no meaningful external
    /// frame rate to report. The display link does not drive them.
    public private(set) var contentFrameRate: Int?
    public private(set) var report: CompatibilityReport

    private var webView: WKWebView?
    private var audioSource: (() -> AudioFrame)?
    private var audioTimer: Timer?
    private let log = Logger(subsystem: "app.diorama", category: "web")

    /// How often analysed audio is handed to the page.
    ///
    /// 30Hz rather than per display refresh: a visualiser redraws on its own animation frame
    /// and only needs the numbers to be current, and evaluating JavaScript is not free.
    private static let audioUpdatesPerSecond = 30.0

    public override init() {
        report = CompatibilityReport(wallpaperID: "")
        super.init()
    }

    public func start(_ request: WallpaperRequest, on surface: DesktopSurface) throws {
        stop()
        report = CompatibilityReport(wallpaperID: request.id)

        guard FileManager.default.fileExists(atPath: request.contentURL.path) else {
            throw BackendError.contentMissing(request.contentURL)
        }

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        // Autoplay is always allowed, and silence is achieved by muting the elements instead.
        // `mediaTypesRequiringUserActionForPlayback` gates video as well as audio, and every
        // web wallpaper in the first real library tested uses video as its background — so
        // "muted" stopped them animating at all rather than merely stopping the sound.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()

        // The host API a web wallpaper is written against, in place before any of its own
        // scripts run. Without it, the first call to `wallpaperRegisterAudioListener` throws
        // and the wallpaper's script stops there.
        configuration.userContentController.addUserScript(
            WebWallpaperBridge.userScript(
                properties: request.webProperties, isMuted: request.isMuted
            )
        )

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        // Never interactive: the desktop must keep behaving like the desktop.
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false

        webView = view
        surface.mount(view)

        // Grant read access to the wallpaper's own directory and nothing above it.
        view.loadFileURL(request.contentURL, allowingReadAccessTo: request.baseURL)
        log.info("loading \(request.contentURL.lastPathComponent, privacy: .public)")
    }

    public func stop() {
        audioTimer?.invalidate()
        audioTimer = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }

    public func setAudioSource(_ source: (() -> AudioFrame)?) {
        audioSource = source
        audioTimer?.invalidate()
        audioTimer = nil
        guard source != nil else { return }

        // The bridge pushes silence on its own when nothing else does, so this takes over from
        // that rather than adding a second stream of frames.
        let timer = Timer.scheduledTimer(
            withTimeInterval: 1 / Self.audioUpdatesPerSecond, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushAudio() }
        }
        RunLoop.main.add(timer, forMode: .common)
        audioTimer = timer
    }

    /// Hands the page one frame of spectrum data in the shape its listeners expect.
    ///
    /// Wallpaper Engine delivers 128 floats: 64 bands for the left channel then 64 for the
    /// right, which is exactly what the analyser already produces.
    private func pushAudio() {
        guard let webView, let frame = audioSource?() else { return }
        let values = (frame.left + frame.right)
            .map { String(format: "%.4f", $0.isFinite ? $0 : 0) }
            .joined(separator: ",")
        webView.evaluateJavaScript(
            "window.__dioramaAudioLive = true; window.__dioramaPushAudio([" + values + "]);"
        )
    }

    public func setPaused(_ paused: Bool) {
        // There is no public API to halt a page's rAF loop, but WebKit already throttles timers
        // and animation in a window the compositor reports as not visible, and the surface is
        // hidden by the time this is called. Hiding the view makes that explicit rather than
        // relying on the behaviour being inferred.
        webView?.isHidden = paused
    }
}

extension WebBackend: WKNavigationDelegate {
    /// Uses the async form deliberately. The completion-handler overload is easy to spell
    /// subtly wrong, and Swift then treats it as a new method that merely "nearly matches" the
    /// protocol requirement — it compiles with a warning, is never called, and every navigation
    /// is allowed. For a method whose entire job is blocking network access, failing open like
    /// that is the worst possible outcome.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }

        // file: and about: only. Everything else — http, https, and any custom scheme a
        // wallpaper might try to hand to the system — is refused and recorded, so the user can
        // see in the compatibility report that the wallpaper tried to reach the network.
        guard url.isFileURL || url.scheme == "about" else {
            log.warning("blocked navigation to \(url.scheme ?? "?", privacy: .public) URL")
            report.add(
                .degraded, feature: "Network access",
                detail: "this wallpaper tried to load remote content, which was blocked"
            )
            return .cancel
        }
        return .allow
    }

    public func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
    ) {
        report.add(.unsupported, feature: "Page load", detail: error.localizedDescription)
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        report.add(.unsupported, feature: "Page load", detail: error.localizedDescription)
    }
}
