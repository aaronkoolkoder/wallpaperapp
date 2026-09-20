import Foundation
import Testing
import WEFormat
import WebKit
@testable import PlayerCore

@Suite("WebWallpaperBridge")
@MainActor
struct WebWallpaperBridgeTests {

    /// Loads `html` with the bridge installed and returns whatever the page recorded.
    private func run(_ html: String, isMuted: Bool = true) async throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(
            WebWallpaperBridge.userScript(properties: [:], isMuted: isMuted)
        )

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString(html, baseURL: nil)

        // Poll rather than wait on a delegate: the page records its own result, and the test
        // only needs to know when that value exists.
        for _ in 0 ..< 100 {
            try? await Task.sleep(for: .milliseconds(50))
            let value = try? await view.evaluateJavaScript("window.__result ?? null")
            if let text = value as? String { return text }
        }
        return "(timed out)"
    }

    @Test("A wallpaper calling the audio listener does not throw")
    func audioListenerExists() async throws {
        // Two of the four web wallpapers in a real library call this on their first line. On a
        // host that does not define it the call throws a TypeError, the script dies there, and
        // the page renders blank — which is indistinguishable from a broken wallpaper.
        let result = try await run("""
        <html><body><script>
        try {
            window.wallpaperRegisterAudioListener(function (data) {
                if (data && data.length === 128) { window.__result = 'audio:' + data.length; }
            });
        } catch (e) { window.__result = 'threw: ' + e.message; }
        </script></body></html>
        """)
        #expect(result == "audio:128", "got \(result)")
    }

    @Test("Declared properties reach the wallpaper's listener")
    func propertiesAreApplied() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WebWallpaperBridge.userScript(
                properties: [
                    "speed": WEProperty(type: .slider, value: .number(0.5)),
                    "tint": WEProperty(type: .color, value: .string("1 0 0")),
                ],
                isMuted: true
            )
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString("""
        <html><body><script>
        window.wallpaperPropertyListener = {
            applyUserProperties: function (p) {
                window.__result = p.speed.value + '|' + p.tint.value;
            }
        };
        </script></body></html>
        """, baseURL: nil)

        var result = "(timed out)"
        for _ in 0 ..< 100 {
            try? await Task.sleep(for: .milliseconds(50))
            if let text = try? await view.evaluateJavaScript("window.__result ?? null") as? String {
                result = text
                break
            }
        }
        #expect(result == "0.5|1 0 0", "got \(result)")
    }

    @Test("The other host functions exist so calling one cannot stop a script")
    func hostFunctionsExist() async throws {
        let result = try await run("""
        <html><body><script>
        var names = ['wallpaperRegisterAudioListener', 'wallpaperRequestRandomFileForProperty',
                     'wallpaperRegisterMediaStatusListener', 'wallpaperRegisterMediaPropertiesListener',
                     'wallpaperRegisterMediaThumbnailListener', 'wallpaperRegisterMediaTimelineListener',
                     'wallpaperRegisterMediaPlaybackListener'];
        var missing = names.filter(function (n) { return typeof window[n] !== 'function'; });
        window.__result = missing.length ? 'missing: ' + missing.join(',') : 'all present';
        </script></body></html>
        """)
        #expect(result == "all present", "got \(result)")
    }

    @Test("Video is muted rather than blocked")
    func videoIsMutedNotBlocked() async throws {
        // Blocking autoplay to keep a wallpaper quiet also stops its video background, which is
        // how every web wallpaper in the library tested renders its motion. Muting keeps the
        // picture and drops the sound.
        let result = try await run("""
        <html><body><video id="v" autoplay loop></video><script>
        window.addEventListener('load', function () {
            setTimeout(function () {
                var v = document.getElementById('v');
                window.__result = v.muted ? 'muted' : 'audible';
            }, 120);
        });
        </script></body></html>
        """)
        #expect(result == "muted", "got \(result)")
    }

    @Test("A property value with quotes cannot break the injected script")
    func escapesPropertyText() {
        // Manifests are untrusted content; an unescaped quote would end the script early and
        // take the whole host API with it.
        let payload = WebWallpaperBridge.propertyPayload([
            "evil": WEProperty(type: .text, value: .string("a\"b\\c\nd"))
        ])
        #expect(payload.contains("\\\""))
        #expect(payload.contains("\\\\"))
        #expect(payload.contains("\\n"))
        #expect(!payload.contains("\na"))
    }
}
