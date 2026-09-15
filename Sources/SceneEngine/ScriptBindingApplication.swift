import Foundation
import simd

/// Reading and writing the layer properties SceneScript can animate.
///
/// Kept apart from ``RenderableLayer`` itself so the layer stays a plain value type with no
/// string-keyed access in its own surface — the stringly-typed lookup is a consequence of the
/// script format, not something the renderer should inherit.
extension RenderableLayer {
    /// Current value of a scripted property, handed to the script as its input.
    func scriptValue(for property: String) -> ScriptValue {
        switch property {
        case "alpha":
            .number(Double(tint.w))
        case "origin":
            .vector3(SIMD3(Double(origin.x), Double(origin.y), Double(origin.z)))
        case "angles":
            // Scripts work in degrees, matching how the format authors them; the layer stores
            // radians. Converting in both directions here keeps the unit boundary in one place.
            .vector3(
                SIMD3(
                    Double(angles.x) * 180 / .pi,
                    Double(angles.y) * 180 / .pi,
                    Double(angles.z) * 180 / .pi
                )
            )
        case "scale":
            .vector3(SIMD3(Double(scale.x), Double(scale.y), Double(scale.z)))
        case "color":
            .vector3(SIMD3(Double(tint.x), Double(tint.y), Double(tint.z)))
        case "size":
            .vector2(SIMD2(Double(size.x), Double(size.y)))
        default:
            .number(0)
        }
    }

    /// Write a script's result back.
    ///
    /// Non-finite results are dropped. A script dividing by zero would otherwise write NaN into
    /// a transform, and a NaN in a matrix silently removes the layer from the screen with no
    /// error anywhere — one of the more baffling failure modes to debug from a screenshot.
    mutating func applyScriptValue(_ value: ScriptValue, to property: String) {
        switch (property, value) {
        case ("alpha", .number(let alpha)):
            guard alpha.isFinite else { return }
            tint.w = Float(alpha)

        case ("origin", .vector3(let v)):
            guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { return }
            origin = SIMD3(Float(v.x), Float(v.y), Float(v.z))

        case ("angles", .vector3(let v)):
            guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { return }
            angles = SIMD3(
                Float(v.x) * .pi / 180, Float(v.y) * .pi / 180, Float(v.z) * .pi / 180
            )

        case ("scale", .vector3(let v)):
            guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { return }
            scale = SIMD3(Float(v.x), Float(v.y), Float(v.z))

        case ("color", .vector3(let v)):
            guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { return }
            tint.x = Float(v.x)
            tint.y = Float(v.y)
            tint.z = Float(v.z)

        case ("size", .vector2(let v)):
            guard v.x.isFinite, v.y.isFinite else { return }
            size = SIMD2(Float(v.x), Float(v.y))

        case ("scale", .number(let uniform)):
            // A script returning a single number for a vector property means "all components",
            // which content does often enough to be worth honouring rather than ignoring.
            guard uniform.isFinite else { return }
            scale = SIMD3(repeating: Float(uniform))

        default:
            // Type mismatch between what the script returned and what the property needs.
            break
        }
    }
}
