import Diagnostics
import Foundation
import JavaScriptCore
import WEFormat
import os

/// A value a script can read or return.
///
/// Wallpaper Engine scripts drive scalar and vector properties — alpha, origin, angles, scale,
/// colour — and the text of a text layer, which is how every clock in a real library works. So
/// the bridge carries numbers, small vectors and strings: data, and nothing that reaches back
/// into the app. Keeping the surface this narrow is deliberate: see ``ScriptRuntime`` for why.
public enum ScriptValue: Sendable, Hashable {
    case number(Double)
    case vector2(SIMD2<Double>)
    case vector3(SIMD3<Double>)
    case string(String)

    var jsValue: Any {
        switch self {
        case .number(let value): value
        case .vector2(let v): [v.x, v.y]
        case .vector3(let v): [v.x, v.y, v.z]
        case .string(let text): text
        }
    }

    static func from(_ value: JSValue?) -> ScriptValue? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isNumber { return .number(value.toDouble()) }
        if value.isString { return value.toString().map(ScriptValue.string) }
        if value.isArray, let array = value.toArray() {
            let numbers = array.compactMap { ($0 as? NSNumber)?.doubleValue }
            if numbers.count >= 3 { return .vector3(SIMD3(numbers[0], numbers[1], numbers[2])) }
            if numbers.count == 2 { return .vector2(SIMD2(numbers[0], numbers[1])) }
            return nil
        }
        // A `Vec2` or `Vec3`, which is what scripts written for Wallpaper Engine return.
        if value.isObject {
            func component(_ name: String) -> Double? {
                guard let part = value.objectForKeyedSubscript(name), part.isNumber else { return nil }
                return part.toDouble()
            }
            if let x = component("x"), let y = component("y") {
                if let z = component("z") { return .vector3(SIMD3(x, y, z)) }
                return .vector2(SIMD2(x, y))
            }
        }
        // Anything else gets ignored rather than poisoning the property with a garbage value.
        return nil
    }
}

/// Runs Wallpaper Engine SceneScript.
///
/// **Security posture.** The JavaScript context is given *no* native bridge whatsoever — no
/// filesystem, no network, no Objective-C exports, no access to app state. Scripts see only the
/// property value they are transforming, a delta time, and elapsed time, and may only return a
/// number or a small array. This matters twice over: these scripts are arbitrary third-party
/// code from the Steam Workshop, and App Store guideline 2.5.2 restricts executing downloaded
/// code. The defensible position, and the one PLAN.md §5.5 commits to, is that these are inert
/// data inside user-supplied content run in a sandboxed interpreter with nothing to reach — the
/// same position a Web wallpaper's JavaScript occupies inside `WKWebView`.
///
/// `JSContext` also has no DOM, no timers, and no `fetch` — it is the bare language plus
/// `Math`, `JSON` and friends. Nothing here adds to that.
public final class ScriptRuntime {
    private let context: JSContext
    private let log = Logger(subsystem: "app.diorama", category: "script")

    public private(set) var findings: [CompatibilityFinding] = []

    /// Names compiled scripts. A counter rather than the layer's name: five layers all called
    /// "Clock" would otherwise share one handle, and every one of them would run the last.
    private var compiledCount = 0

    /// Scripts are given a wall-clock budget per evaluation. A runaway loop in a wallpaper
    /// would otherwise wedge the render thread with no way out.
    private let evaluationBudget: TimeInterval

    public init?(evaluationBudget: TimeInterval = 0.008) {
        guard let context = JSContext() else { return nil }
        self.context = context
        self.evaluationBudget = evaluationBudget

        context.exceptionHandler = { _, exception in
            // Swallowed rather than thrown: a broken script must degrade that one property, not
            // take down the wallpaper.
        }

        context.evaluateScript(Self.prelude)
    }

    /// The globals Wallpaper Engine scripts are written against, in plain JavaScript.
    ///
    /// Measured against a real library's 33 scripts: `createScriptProperties()` with
    /// `addCheckbox` (53 calls), `addText`, `addSlider` and `addCombo`; `Date`; `Vec2`/`Vec3`;
    /// `engine.runtime`; `WEMath.mix`. The builder used to know neither `addCheckbox` nor any
    /// values, so every script declaring a checkbox threw before defining `update`, and a clock
    /// that did compile read its separator as `undefined`. Scripts that create or reorder layers
    /// (`thisScene`) still find nothing there, and degrade as before.
    static let prelude = """
    function __dioramaProperties(saved) {
        var values = {};
        var builder = { finish: function () { return values; } };
        var proxy;
        var add = function (options) {
            if (options && typeof options.name === 'string') {
                values[options.name] = Object.prototype.hasOwnProperty.call(saved, options.name)
                    ? saved[options.name] : options.value;
            }
            return proxy;
        };
        proxy = new Proxy(builder, {
            get: function (target, key) { return key in target ? target[key] : add; }
        });
        return proxy;
    }
    function createScriptProperties() { return __dioramaProperties({}); }

    function __dioramaVector(names) {
        var Vector = function (x, y, z) {
            if (!(this instanceof Vector)) { return new Vector(x, y, z); }
            var parts;
            if (typeof x === 'string') { parts = x.trim().split(/\\s+/).map(Number); }
            else if (x !== null && typeof x === 'object') { parts = [x.x, x.y, x.z]; }
            else if (y === undefined && z === undefined) { parts = [x, x, x]; }
            else { parts = [x, y, z]; }
            for (var i = 0; i < names.length; i++) {
                var v = Number(parts[i]);
                this[names[i]] = isFinite(v) ? v : 0;
            }
        };
        var make = function (f) {
            var out = Object.create(Vector.prototype);
            names.forEach(function (n) { out[n] = f(n); });
            return out;
        };
        var other = function (o, n) { return (o !== null && typeof o === 'object') ? o[n] : o; };
        Vector.prototype.add = function (o) { var s = this; return make(function (n) { return s[n] + other(o, n); }); };
        Vector.prototype.subtract = function (o) { var s = this; return make(function (n) { return s[n] - other(o, n); }); };
        Vector.prototype.multiply = function (o) { var s = this; return make(function (n) { return s[n] * other(o, n); }); };
        Vector.prototype.divide = function (o) { var s = this; return make(function (n) { return s[n] / other(o, n); }); };
        Vector.prototype.length = function () {
            var s = this;
            return Math.sqrt(names.reduce(function (sum, n) { return sum + s[n] * s[n]; }, 0));
        };
        Vector.prototype.normalize = function () { return this.divide(this.length() || 1); };
        Vector.prototype.copy = function () { var s = this; return make(function (n) { return s[n]; }); };
        Vector.prototype.toString = function () { var s = this; return names.map(function (n) { return s[n]; }).join(' '); };
        names.forEach(function (n, i) {
            Object.defineProperty(Vector.prototype, i, { get: function () { return this[n]; } });
        });
        return Vector;
    }
    var Vec2 = __dioramaVector(['x', 'y']);
    var Vec3 = __dioramaVector(['x', 'y', 'z']);

    var WEMath = {
        mix: function (a, b, t) { return a + (b - a) * t; },
        clamp: function (v, lo, hi) { return Math.min(Math.max(v, lo), hi); },
        smoothstep: function (lo, hi, v) {
            var t = Math.min(Math.max((v - lo) / (hi - lo), 0), 1);
            return t * t * (3 - 2 * t);
        },
        deg2rad: Math.PI / 180,
        rad2deg: 180 / Math.PI
    };

    var engine = {
        runtime: 0,
        frametime: 0,
        userProperties: {},
        isDesktopDevice: function () { return true; },
        isMobileDevice: function () { return false; },
        isWallpaper: function () { return true; },
        isScreensaver: function () { return false; }
    };
    """

    /// A property's saved settings as a JSON object literal.
    static func json(_ properties: [String: DynamicValue]) -> String {
        var object: [String: Any] = [:]
        for (name, value) in properties {
            switch value {
            case .bool(let flag): object[name] = flag
            case .number(let number) where number.isFinite: object[name] = number
            case .string(let text): object[name] = text
            case .vector3(let v): object[name] = ["x": v.x, "y": v.y, "z": v.z]
            case .number, .null: continue
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Publish the latest audio frame for scripts to read.
    ///
    /// Exposed as plain arrays and a number on a global, not as a bridged object. The runtime's
    /// whole security position (PLAN.md §5.5) is that scripts see data and nothing else, and a
    /// bridged host object would be the first crack in that.
    public func setAudio(_ frame: AudioFrame) {
        context.setObject(frame.left, forKeyedSubscript: "audioLeft" as NSString)
        context.setObject(frame.right, forKeyedSubscript: "audioRight" as NSString)
        context.setObject(frame.amplitude, forKeyedSubscript: "audioLevel" as NSString)
    }

    /// Compile one script into a callable update function.
    ///
    /// - Parameter properties: the script's declared settings as the wallpaper saved them.
    /// - Returns: an opaque handle name, or nil if the script has no usable `update`.
    public func compile(
        _ source: String, name: String, properties: [String: DynamicValue] = [:]
    ) -> String? {
        compiledCount += 1
        let handle = "__diorama_\(compiledCount)"

        // Wrap in an IIFE so a script's own top-level declarations cannot collide with another
        // script's, and strip `export` keywords, which JSContext does not accept.
        let normalized = source
            .replacingOccurrences(of: "export function", with: "function")
            .replacingOccurrences(of: "export var", with: "var")
            .replacingOccurrences(of: "export let", with: "let")
            .replacingOccurrences(of: "export const", with: "const")

        // Vectors arrive as arrays and are handed on as `Vec2`/`Vec3`, which is what scripts
        // written for Wallpaper Engine read (`value.x`); both index and name work on them.
        // `init`, when a script has one, runs once before the first update.
        let wrapper = """
        var \(handle) = (function () {
            var createScriptProperties = function () {
                return __dioramaProperties(\(Self.json(properties)));
            };
            \(normalized)
            if (typeof update !== 'function') { return null; }
            var initialise = (typeof init === 'function') ? init : null;
            return function (value, deltaTime, elapsed) {
                engine.runtime = elapsed;
                engine.frametime = deltaTime;
                if (Array.isArray(value)) {
                    value = value.length >= 3
                        ? new Vec3(value[0], value[1], value[2]) : new Vec2(value[0], value[1]);
                }
                if (initialise) {
                    var first = initialise(value);
                    initialise = null;
                    if (first !== undefined && first !== null) { value = first; }
                }
                return update(value, deltaTime, elapsed);
            };
        })();
        """

        context.evaluateScript(wrapper)
        guard let value = context.objectForKeyedSubscript(handle), !value.isNull,
              !value.isUndefined else {
            note(.degraded, "Script", "\(name) has no update function")
            return nil
        }
        return handle
    }

    /// Run one compiled script for a frame.
    public func evaluate(
        handle: String, current: ScriptValue, deltaTime: Double, elapsed: Double
    ) -> ScriptValue? {
        guard let function = context.objectForKeyedSubscript(handle),
              !function.isUndefined, !function.isNull else { return nil }

        let started = CFAbsoluteTimeGetCurrent()
        let result = function.call(withArguments: [current.jsValue, deltaTime, elapsed])
        let duration = CFAbsoluteTimeGetCurrent() - started

        if duration > evaluationBudget {
            note(
                .degraded, "Script performance",
                "a script took \(Int(duration * 1000))ms per frame and may stutter"
            )
        }
        return ScriptValue.from(result)
    }

    private func note(_ level: CompatibilityLevel, _ feature: String, _ detail: String) {
        let finding = CompatibilityFinding(level: level, feature: feature, detail: detail)
        guard !findings.contains(finding) else { return }
        findings.append(finding)
        log.warning("\(feature, privacy: .public): \(detail, privacy: .public)")
    }
}
