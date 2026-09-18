import Foundation
import Testing
import simd
@testable import SceneEngine

@Suite("ScriptRuntime")
struct ScriptRuntimeTests {

    @Test("Compiles and runs an update function")
    func runsUpdate() throws {
        let runtime = try #require(ScriptRuntime())
        let handle = try #require(runtime.compile(
            "export function update(value, deltaTime, t) { return value + 1; }", name: "t"
        ))
        let result = runtime.evaluate(handle: handle, current: .number(5), deltaTime: 0.016, elapsed: 1)
        #expect(result == .number(6))
    }

    @Test("Handles the module syntax Wallpaper Engine scripts are written in")
    func stripsExports() throws {
        let runtime = try #require(ScriptRuntime())
        let source = """
        'use strict';
        export var scriptProperties = createScriptProperties()
            .addSlider({name: 'speed', label: 'Speed', value: 2, min: 0, max: 10})
            .finish();

        export function update(value, deltaTime, t) {
            return value * 2;
        }
        """
        // `export` is not valid in a JSContext script, and the createScriptProperties bootstrap
        // does not exist there — both have to be handled or every real script fails to compile.
        let handle = try #require(runtime.compile(source, name: "t"))
        #expect(runtime.evaluate(handle: handle, current: .number(3), deltaTime: 0, elapsed: 0) == .number(6))
    }

    @Test("A script with no update function is reported, not silently accepted")
    func missingUpdateReported() throws {
        let runtime = try #require(ScriptRuntime())
        #expect(runtime.compile("var x = 1;", name: "broken") == nil)
        #expect(runtime.findings.contains { $0.feature == "Script" })
    }

    @Test("A syntactically broken script degrades that property only")
    func brokenScriptDoesNotThrow() throws {
        let runtime = try #require(ScriptRuntime())
        // Must not trap or throw — a broken script in one wallpaper cannot take the app down.
        _ = runtime.compile("function update( { syntax error", name: "bad")
        let handle = runtime.compile("export function update(v) { return v; }", name: "good")
        #expect(handle != nil)
    }

    @Test("Vectors round-trip")
    func vectorRoundTrip() throws {
        let runtime = try #require(ScriptRuntime())
        let handle = try #require(runtime.compile(
            "export function update(v) { return [v[0] + 1, v[1] + 2, v[2] + 3]; }", name: "t"
        ))
        let result = runtime.evaluate(
            handle: handle, current: .vector3(SIMD3(1, 1, 1)), deltaTime: 0, elapsed: 0
        )
        #expect(result == .vector3(SIMD3(2, 3, 4)))
    }

    @Test("Elapsed time reaches the script")
    func timeIsPassedThrough() throws {
        let runtime = try #require(ScriptRuntime())
        let handle = try #require(runtime.compile(
            "export function update(value, deltaTime, t) { return t; }", name: "t"
        ))
        #expect(runtime.evaluate(handle: handle, current: .number(0), deltaTime: 0.016, elapsed: 42) == .number(42))
    }

    @Test("A non-numeric return is ignored rather than poisoning the property")
    func rejectsNonNumeric() throws {
        let runtime = try #require(ScriptRuntime())
        let handle = try #require(runtime.compile(
            "export function update(v) { return 'hello'; }", name: "t"
        ))
        #expect(runtime.evaluate(handle: handle, current: .number(1), deltaTime: 0, elapsed: 0) == nil)
    }

    // MARK: - Security
    //
    // The runtime deliberately exposes no native bridge. These tests pin that, because the
    // App Store position in PLAN.md §5.5 depends on it and a future convenience export would
    // quietly invalidate it.

    @Test("No filesystem access is reachable from a script")
    func noFilesystemBridge() throws {
        let runtime = try #require(ScriptRuntime())
        let handle = try #require(runtime.compile("""
        export function update(v) {
            if (typeof require !== 'undefined') { return 1; }
            if (typeof process !== 'undefined') { return 2; }
            if (typeof FileManager !== 'undefined') { return 3; }
            if (typeof NSFileManager !== 'undefined') { return 4; }
            return 0;
        }
        """, name: "probe"))
        #expect(runtime.evaluate(handle: handle, current: .number(0), deltaTime: 0, elapsed: 0) == .number(0))
    }

    @Test("No network access is reachable from a script")
    func noNetworkBridge() throws {
        let runtime = try #require(ScriptRuntime())
        let handle = try #require(runtime.compile("""
        export function update(v) {
            if (typeof fetch !== 'undefined') { return 1; }
            if (typeof XMLHttpRequest !== 'undefined') { return 2; }
            if (typeof WebSocket !== 'undefined') { return 3; }
            return 0;
        }
        """, name: "probe"))
        #expect(runtime.evaluate(handle: handle, current: .number(0), deltaTime: 0, elapsed: 0) == .number(0))
    }

    @Test("No app state or DOM is reachable from a script")
    func noAppStateBridge() throws {
        let runtime = try #require(ScriptRuntime())
        let handle = try #require(runtime.compile("""
        export function update(v) {
            if (typeof document !== 'undefined') { return 1; }
            if (typeof window !== 'undefined') { return 2; }
            if (typeof diorama !== 'undefined') { return 3; }
            return 0;
        }
        """, name: "probe"))
        #expect(runtime.evaluate(handle: handle, current: .number(0), deltaTime: 0, elapsed: 0) == .number(0))
    }

    @Test("Scripts cannot collide with one another's declarations")
    func scriptsAreIsolated() throws {
        let runtime = try #require(ScriptRuntime())
        let first = try #require(runtime.compile(
            "var secret = 10; export function update(v) { return secret; }", name: "a"
        ))
        let second = try #require(runtime.compile(
            "var secret = 20; export function update(v) { return secret; }", name: "b"
        ))
        // Each script's top-level declarations are wrapped, so loading one cannot rewrite the
        // behaviour of another already running in the same scene.
        #expect(runtime.evaluate(handle: first, current: .number(0), deltaTime: 0, elapsed: 0) == .number(10))
        #expect(runtime.evaluate(handle: second, current: .number(0), deltaTime: 0, elapsed: 0) == .number(20))
    }
}

@Suite("Script property application")
struct ScriptPropertyTests {

    private func layer() -> RenderableLayer {
        RenderableLayer(
            name: "l", origin: .zero, angles: .zero, scale: SIMD3(1, 1, 1),
            size: SIMD2(10, 10), tint: SIMD4(1, 1, 1, 1), blend: .premultipliedAlpha,
            texture: nil, parallaxDepth: .zero, isVisible: true
        )
    }

    @Test("Alpha round-trips through the script bridge")
    func alphaRoundTrip() {
        var l = layer()
        l.applyScriptValue(.number(0.25), to: "alpha")
        #expect(abs(l.tint.w - 0.25) < 0.0001)
        #expect(l.scriptValue(for: "alpha") == .number(0.25))
    }

    @Test("Angles convert between the script's degrees and the layer's radians")
    func anglesConvertUnits() {
        var l = layer()
        l.applyScriptValue(.vector3(SIMD3(0, 0, 90)), to: "angles")
        #expect(abs(l.angles.z - .pi / 2) < 0.0001)

        // And back out again, so a script reading its own previous value sees degrees.
        if case .vector3(let v) = l.scriptValue(for: "angles") {
            #expect(abs(v.z - 90) < 0.001)
        } else {
            Issue.record("expected a vector")
        }
    }

    @Test("A NaN result is dropped rather than written into a transform")
    func rejectsNaN() {
        var l = layer()
        let original = l.origin
        // A NaN in a matrix silently removes the layer from the screen with no error anywhere,
        // which is among the more baffling things to debug from a screenshot.
        l.applyScriptValue(.vector3(SIMD3(Double.nan, 0, 0)), to: "origin")
        #expect(l.origin == original)
    }

    @Test("An infinite result is dropped")
    func rejectsInfinity() {
        var l = layer()
        l.applyScriptValue(.number(Double.infinity), to: "alpha")
        #expect(l.tint.w == 1)
    }

    @Test("A scalar applied to scale means all components")
    func scalarScaleBroadcasts() {
        var l = layer()
        l.applyScriptValue(.number(3), to: "scale")
        #expect(l.scale == SIMD3(3, 3, 3))
    }

    @Test("A type mismatch leaves the property untouched")
    func typeMismatchIgnored() {
        var l = layer()
        let original = l.tint
        l.applyScriptValue(.vector2(SIMD2(1, 2)), to: "alpha")
        #expect(l.tint == original)
    }
}

@Suite("Script audio bridge")
struct ScriptAudioTests {

    @Test("Scripts can read the audio level")
    func readsLevel() throws {
        let runtime = try #require(ScriptRuntime())
        var frame = AudioFrame.silent
        frame.amplitude = 0.75
        runtime.setAudio(frame)

        let handle = try #require(runtime.compile(
            "export function update(v) { return audioLevel; }", name: "t"
        ))
        let result = runtime.evaluate(
            handle: handle, current: .number(0), deltaTime: 0, elapsed: 0
        )
        if case .number(let value) = result {
            #expect(abs(value - 0.75) < 0.001)
        } else {
            Issue.record("expected a number")
        }
    }

    @Test("Scripts can read individual bands")
    func readsBands() throws {
        let runtime = try #require(ScriptRuntime())
        var frame = AudioFrame.silent
        frame.left[3] = 0.5
        runtime.setAudio(frame)

        let handle = try #require(runtime.compile(
            "export function update(v) { return audioLeft[3]; }", name: "t"
        ))
        if case .number(let value) = runtime.evaluate(
            handle: handle, current: .number(0), deltaTime: 0, elapsed: 0
        ) {
            #expect(abs(value - 0.5) < 0.001)
        } else {
            Issue.record("expected a number")
        }
    }

    @Test("Audio is exposed as plain data, not a bridged host object")
    func audioIsPlainData() throws {
        // The runtime's security position is that scripts see data and nothing else; a bridged
        // object would be the first crack in it.
        let runtime = try #require(ScriptRuntime())
        runtime.setAudio(.silent)
        let handle = try #require(runtime.compile("""
        export function update(v) {
            if (typeof audioLeft.stop === 'function') { return 1; }
            if (typeof audioLeft.start === 'function') { return 2; }
            return Array.isArray(audioLeft) ? 0 : 3;
        }
        """, name: "probe"))
        #expect(
            runtime.evaluate(handle: handle, current: .number(0), deltaTime: 0, elapsed: 0)
                == .number(0)
        )
    }

    @Test("A scene with no audio enabled sees silence rather than undefined")
    func silentByDefault() throws {
        let runtime = try #require(ScriptRuntime())
        runtime.setAudio(.silent)
        let handle = try #require(runtime.compile(
            "export function update(v) { return audioLevel; }", name: "t"
        ))
        #expect(
            runtime.evaluate(handle: handle, current: .number(0), deltaTime: 0, elapsed: 0)
                == .number(0)
        )
    }
}
