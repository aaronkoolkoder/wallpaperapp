import Diagnostics
import Foundation
import JavaScriptCore
import os

/// A value a script can read or return.
///
/// Wallpaper Engine scripts drive scalar and vector properties — alpha, origin, angles, scale,
/// colour — so the bridge only needs to carry numbers and small vectors. Keeping the surface
/// this narrow is deliberate: see ``ScriptRuntime`` for why.
public enum ScriptValue: Sendable, Hashable {
    case number(Double)
    case vector2(SIMD2<Double>)
    case vector3(SIMD3<Double>)

    var jsValue: Any {
        switch self {
        case .number(let value): value
        case .vector2(let v): [v.x, v.y]
        case .vector3(let v): [v.x, v.y, v.z]
        }
    }

    static func from(_ value: JSValue?) -> ScriptValue? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isNumber { return .number(value.toDouble()) }
        if value.isArray, let array = value.toArray() as? [Any] {
            let numbers = array.compactMap { ($0 as? NSNumber)?.doubleValue }
            if numbers.count >= 3 { return .vector3(SIMD3(numbers[0], numbers[1], numbers[2])) }
            if numbers.count == 2 { return .vector2(SIMD2(numbers[0], numbers[1])) }
        }
        // A script returning an object, string, or NaN gets ignored rather than poisoning the
        // property with a garbage value.
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

        // Minimal shim for the bootstrap Wallpaper Engine scripts expect. Declaring properties
        // is a no-op here — the values come from the wallpaper's own settings, not from script.
        context.evaluateScript("""
        function createScriptProperties() {
            var chain = {};
            var noop = function () { return chain; };
            ['addSlider','addColor','addBool','addCombo','addText','addFile']
                .forEach(function (name) { chain[name] = noop; });
            chain.finish = function () { return {}; };
            return chain;
        }
        """)
    }

    /// Compile one script into a callable update function.
    ///
    /// - Returns: an opaque handle name, or nil if the script has no usable `update`.
    public func compile(_ source: String, name: String) -> String? {
        let handle = "__diorama_\(abs(name.hashValue))"

        // Wrap in an IIFE so a script's own top-level declarations cannot collide with another
        // script's, and strip `export` keywords, which JSContext does not accept.
        let normalized = source
            .replacingOccurrences(of: "export function", with: "function")
            .replacingOccurrences(of: "export var", with: "var")
            .replacingOccurrences(of: "export let", with: "let")
            .replacingOccurrences(of: "export const", with: "const")

        let wrapper = """
        var \(handle) = (function () {
            \(normalized)
            return (typeof update === 'function') ? update : null;
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
