import Foundation
import WEFormat
import WebKit

/// The JavaScript Wallpaper Engine puts in front of a web wallpaper.
///
/// Web wallpapers are written against a small host API — they call
/// `window.wallpaperRegisterAudioListener` to get spectrum data, and define
/// `window.wallpaperPropertyListener` for the engine to push settings into. On a host that does
/// not provide those, calling an undefined function throws a TypeError, the wallpaper's script
/// dies at that line, and the page renders as a blank background. Two of the four web
/// wallpapers in the first real library tested call the audio listener on their first line.
///
/// Every function here is defined so that a wallpaper runs rather than throws. Where the real
/// engine would supply data this project does not have, the shim supplies something inert and
/// well-formed rather than nothing — a silent spectrum is a wallpaper that renders quietly; a
/// missing function is a wallpaper that does not render at all.
enum WebWallpaperBridge {

    /// Injected before any of the page's own scripts run.
    @MainActor
    static func userScript(properties: [String: WEProperty], isMuted: Bool) -> WKUserScript {
        WKUserScript(
            source: hostAPI(properties: properties, isMuted: isMuted),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    /// The property payload in the shape `applyUserProperties` expects: each key maps to an
    /// object with a `value`, and colours arrive as the `"r g b"` strings the format uses.
    static func propertyPayload(_ properties: [String: WEProperty]) -> String {
        var entries: [String] = []
        for (key, property) in properties.sorted(by: { $0.key < $1.key }) {
            guard let json = jsonValue(for: property) else { continue }
            entries.append("\(quoted(key)): { \"value\": \(json) }")
        }
        return "{" + entries.joined(separator: ", ") + "}"
    }

    private static func jsonValue(for property: WEProperty) -> String? {
        switch property.value {
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return String(number)
        case .string(let text): return quoted(text)
        case .vector3(let vector): return quoted("\(vector.x) \(vector.y) \(vector.z)")
        case .null, .none: return nil
        }
    }

    /// Minimal JSON string escaping. Property text comes from a wallpaper's manifest and is not
    /// trusted to be free of quotes or newlines.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }

    private static func hostAPI(properties: [String: WEProperty], isMuted: Bool) -> String {
        """
        (function () {
          'use strict';
          if (window.__dioramaBridge) { return; }
          window.__dioramaBridge = true;

          // Audio. Wallpapers expect 128 floats: 64 bands per channel. Silence is delivered on
          // a timer rather than not at all, because a visualiser that never receives a frame
          // shows nothing and looks broken, while one receiving silence sits at rest.
          var audioListeners = [];
          window.wallpaperRegisterAudioListener = function (callback) {
            if (typeof callback === 'function') { audioListeners.push(callback); }
          };
          window.__dioramaPushAudio = function (data) {
            for (var i = 0; i < audioListeners.length; i++) {
              try { audioListeners[i](data); } catch (e) {}
            }
          };
          var silence = new Array(128).fill(0);
          setInterval(function () {
            if (!window.__dioramaAudioLive) { window.__dioramaPushAudio(silence); }
          }, 1000 / 30);

          // Settings the user has changed. The wallpaper defines the listener; the host calls
          // it. Deferred to load so a listener assigned by a later script still receives them.
          var properties = \(propertyPayload(properties));
          window.__dioramaApplyProperties = function (values) {
            var listener = window.wallpaperPropertyListener;
            if (listener && typeof listener.applyUserProperties === 'function') {
              try { listener.applyUserProperties(values); } catch (e) {}
            }
          };
          window.addEventListener('load', function () {
            window.__dioramaApplyProperties(properties);
            var listener = window.wallpaperPropertyListener;
            if (listener && typeof listener.applyGeneralProperties === 'function') {
              try { listener.applyGeneralProperties({ fps: 60 }); } catch (e) {}
            }
          });

          // File pickers. The real engine answers with a file the user chose; nothing here has
          // been chosen, so the callback is never invoked — which leaves the wallpaper on its
          // own default rather than handing it a path that does not exist.
          window.wallpaperRequestRandomFileForProperty = function (name, callback) {};
          window.wallpaperRegisterMediaStatusListener = function () {};
          window.wallpaperRegisterMediaPropertiesListener = function () {};
          window.wallpaperRegisterMediaThumbnailListener = function () {};
          window.wallpaperRegisterMediaTimelineListener = function () {};
          window.wallpaperRegisterMediaPlaybackListener = function () {};
          window.wallpaperPluginListener = window.wallpaperPluginListener || {};

          \(isMuted ? muteScript : "")
        })();
        """
    }

    /// Silences media without blocking it.
    ///
    /// The obvious way to keep a wallpaper quiet is `mediaTypesRequiringUserActionForPlayback`,
    /// but that gates *video* too — and every web wallpaper in the library tested uses video as
    /// its background, so being muted stopped them animating at all. Muting each element keeps
    /// the picture and drops the sound, which is what "muted" was supposed to mean.
    private static let muteScript = """
          var mute = function (node) {
            if (node && (node.tagName === 'VIDEO' || node.tagName === 'AUDIO')) {
              node.muted = true;
              node.volume = 0;
            }
          };
          var muteAll = function () {
            var media = document.querySelectorAll('video, audio');
            for (var i = 0; i < media.length; i++) { mute(media[i]); }
          };
          document.addEventListener('DOMContentLoaded', muteAll);
          window.addEventListener('load', muteAll);
          // Wallpapers create their media elements from script, often well after load.
          new MutationObserver(function (records) {
            for (var i = 0; i < records.length; i++) {
              var added = records[i].addedNodes;
              for (var j = 0; j < added.length; j++) {
                mute(added[j]);
                if (added[j].querySelectorAll) {
                  var nested = added[j].querySelectorAll('video, audio');
                  for (var k = 0; k < nested.length; k++) { mute(nested[k]); }
                }
              }
            }
          }).observe(document.documentElement, { childList: true, subtree: true });
        """
}
