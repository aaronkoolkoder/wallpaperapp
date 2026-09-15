import AppKit
import Diagnostics
import Foundation
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

    /// Web wallpapers drive their own animation through rAF, so there is no meaningful external
    /// frame rate to report. The display link does not drive them.
    public private(set) var contentFrameRate: Int?
    public private(set) var report: CompatibilityReport

    private var webView: WKWebView?
    private let log = Logger(subsystem: "app.diorama", category: "web")

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
        // Wallpapers are silent unless the user asks otherwise.
        configuration.mediaTypesRequiringUserActionForPlayback = request.isMuted ? .all : []
        configuration.websiteDataStore = .nonPersistent()

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
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
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
