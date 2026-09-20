import Foundation

/// Diorama's own implementations of the shader headers Wallpaper Engine ships with itself.
///
/// Materials and effects `#include "common.h"` and friends, but those files live in the
/// Wallpaper Engine *application*, not inside a wallpaper. Nothing downloaded from the Workshop
/// carries them, so on macOS — where Wallpaper Engine does not run and there is no installation
/// to read them out of — every effect shader fails to compile for want of a header. That is
/// most of the motion in a scene: the sway, the pulse, the water, the shake are all effect
/// shaders, and they *are* packaged. Only their headers are missing.
///
/// **These are written from the interface, never copied.** What the format exposes is a set of
/// names and call signatures — `texSample2D(sampler, uv)`, `mul(a, b)`, `CAST3(x)` — inferred
/// from how shipped shaders call them. Names and signatures are not protected expression; the
/// bodies below are ours, and Wallpaper Engine's versions have not been read. See LEGAL.md.
///
/// Where behaviour is a judgement call it is noted rather than silently guessed. A wrong-looking
/// effect is easier to diagnose than a missing one, but both are worse than a comment.
public enum BuiltinShaderLibrary {

    /// Headers served when a wallpaper does not carry its own.
    ///
    /// A wallpaper that ships its own copy wins: these are a fallback for the ones Wallpaper
    /// Engine would have supplied, not an override.
    public static let headers: [String: String] = [
        "common.h": common,
        "common_vertex.h": commonVertex,
        "common_fragment.h": commonFragment,
        "common_blending.h": commonBlending,
        "common_composite.h": commonComposite,
        "common_blur.h": commonBlur,
    ]

    public static func header(named name: String) -> String? {
        headers[(name as NSString).lastPathComponent]
    }

    // MARK: - common.h

    /// The HLSL-flavoured helpers every shipped shader assumes.
    ///
    /// Wallpaper Engine's shader dialect reads like HLSL written in GLSL — `saturate`, `frac`,
    /// `lerp`, `mul` — which is what most of this bridges.
    static let common = """
    #ifndef DIORAMA_COMMON_H
    #define DIORAMA_COMMON_H

    #define M_PI 3.14159265358979323846
    #define M_PI_2 1.57079632679489661923
    #define M_2PI 6.28318530717958647692

    // Vector splats. Shipped shaders use these wherever a scalar has to widen, e.g.
    // `pow(albedo.rgb, CAST3(g_Power))`.
    #define CAST2(x) vec2(x)
    #define CAST3(x) vec3(x)
    #define CAST4(x) vec4(x)

    // Matrix casts, used to take the upper-left of a projection matrix.
    #define CAST2X2(x) mat2(x)
    #define CAST3X3(x) mat3(x)
    #define CAST4X4(x) mat4(x)

    // `mul(a, b)` is HLSL's multiply. For a vector and a matrix HLSL treats the vector as a
    // row, which is exactly what GLSL's `v * m` does — so one macro covers the matrix cases and
    // the scalar ones both, and does not need an overload per type.
    #define mul(a, b) ((a) * (b))

    float saturate(float v) { return clamp(v, 0.0, 1.0); }
    vec2 saturate(vec2 v) { return clamp(v, 0.0, 1.0); }
    vec3 saturate(vec3 v) { return clamp(v, 0.0, 1.0); }
    vec4 saturate(vec4 v) { return clamp(v, 0.0, 1.0); }

    float frac(float v) { return fract(v); }
    vec2 frac(vec2 v) { return fract(v); }
    vec3 frac(vec3 v) { return fract(v); }
    vec4 frac(vec4 v) { return fract(v); }

    float lerp(float a, float b, float t) { return mix(a, b, t); }
    vec2 lerp(vec2 a, vec2 b, float t) { return mix(a, b, t); }
    vec3 lerp(vec3 a, vec3 b, float t) { return mix(a, b, t); }
    vec4 lerp(vec4 a, vec4 b, float t) { return mix(a, b, t); }

    // The sampling wrapper shipped shaders use in place of `texture2D`, by a wide margin the
    // most-called thing in this header.
    vec4 texSample2D(sampler2D tex, vec2 uv) { return texture(tex, uv); }
    vec4 texSample2DLod(sampler2D tex, vec2 uv, float lod) { return textureLod(tex, uv, lod); }

    /// Rec. 709 luma. Wallpaper Engine's exact weights are not published; these are the
    /// standard ones for sRGB content and are what a greyscale control is expected to look
    /// like. A different set would shift the tint of a desaturated layer slightly, nothing more.
    float greyscale(vec3 colour) { return dot(colour, vec3(0.2126, 0.7152, 0.0722)); }
    float greyscale(vec4 colour) { return greyscale(colour.rgb); }

    vec2 rotateVec2(vec2 v, float angle) {
        float s = sin(angle);
        float c = cos(angle);
        return vec2(v.x * c - v.y * s, v.x * s + v.y * c);
    }

    mat2 rotationMatrix2(float angle) {
        float s = sin(angle);
        float c = cos(angle);
        return mat2(c, s, -s, c);
    }

    #endif
    """

    // MARK: - common_vertex.h / common_fragment.h

    /// Stage-specific helpers. Shipped shaders include these for a handful of conveniences, so
    /// they pull in `common.h` and add little of their own.
    static let commonVertex = """
    #ifndef DIORAMA_COMMON_VERTEX_H
    #define DIORAMA_COMMON_VERTEX_H
    #include "common.h"

    // A full-screen quad's clip position from its unit-quad vertex.
    vec4 vertexFullscreen(vec3 position) { return vec4(position.xy * 2.0, 0.0, 1.0); }

    #endif
    """

    static let commonFragment = """
    #ifndef DIORAMA_COMMON_FRAGMENT_H
    #define DIORAMA_COMMON_FRAGMENT_H
    #include "common.h"

    // Wallpaper Engine textures carry straight alpha while every blend mode here is
    // premultiplied, so a shader that composites by hand needs both directions available.
    vec4 premultiply(vec4 colour) { return vec4(colour.rgb * colour.a, colour.a); }
    vec4 unpremultiply(vec4 colour) {
        return colour.a > 0.0 ? vec4(colour.rgb / colour.a, colour.a) : colour;
    }

    #endif
    """

    // MARK: - common_blending.h

    /// The Photoshop-style blend modes effects select between with a `BLENDMODE` combo.
    ///
    /// The numbering matters: `ApplyBlending` is called with the combo's integer value, so the
    /// order here has to match the order the editor presents. It follows the conventional
    /// Photoshop ordering, which is what the combo labels in shipped content imply.
    /// `TODO(verify):` against real content that switches modes, since a mismatch shows up as
    /// the wrong-but-plausible blend rather than as an error.
    static let commonBlending = """
    #ifndef DIORAMA_COMMON_BLENDING_H
    #define DIORAMA_COMMON_BLENDING_H
    #include "common.h"

    #define BlendNormal 0
    #define BlendDarken 1
    #define BlendMultiply 2
    #define BlendColorBurn 3
    #define BlendLinearBurn 4
    #define BlendLighten 5
    #define BlendScreen 6
    #define BlendColorDodge 7
    #define BlendLinearDodge 8
    #define BlendOverlay 9
    #define BlendSoftLight 10
    #define BlendHardLight 11
    #define BlendVividLight 12
    #define BlendLinearLight 13
    #define BlendPinLight 14
    #define BlendDifference 15
    #define BlendExclusion 16

    vec3 BlendChannels(int mode, vec3 base, vec3 blend) {
        if (mode == BlendDarken)       return min(base, blend);
        if (mode == BlendMultiply)     return base * blend;
        if (mode == BlendColorBurn)    return 1.0 - (1.0 - base) / max(blend, CAST3(0.001));
        if (mode == BlendLinearBurn)   return base + blend - 1.0;
        if (mode == BlendLighten)      return max(base, blend);
        if (mode == BlendScreen)       return 1.0 - (1.0 - base) * (1.0 - blend);
        if (mode == BlendColorDodge)   return base / max(1.0 - blend, CAST3(0.001));
        if (mode == BlendLinearDodge)  return base + blend;
        if (mode == BlendOverlay) {
            return mix(2.0 * base * blend,
                       1.0 - 2.0 * (1.0 - base) * (1.0 - blend),
                       step(CAST3(0.5), base));
        }
        if (mode == BlendSoftLight) {
            return mix(2.0 * base * blend + base * base * (1.0 - 2.0 * blend),
                       sqrt(max(base, CAST3(0.0))) * (2.0 * blend - 1.0)
                           + 2.0 * base * (1.0 - blend),
                       step(CAST3(0.5), blend));
        }
        if (mode == BlendHardLight) {
            return mix(2.0 * base * blend,
                       1.0 - 2.0 * (1.0 - base) * (1.0 - blend),
                       step(CAST3(0.5), blend));
        }
        if (mode == BlendVividLight) {
            return mix(1.0 - (1.0 - base) / max(2.0 * blend, CAST3(0.001)),
                       base / max(2.0 * (1.0 - blend), CAST3(0.001)),
                       step(CAST3(0.5), blend));
        }
        if (mode == BlendLinearLight)  return base + 2.0 * blend - 1.0;
        if (mode == BlendPinLight) {
            return mix(min(base, 2.0 * blend),
                       max(base, 2.0 * blend - 1.0),
                       step(CAST3(0.5), blend));
        }
        if (mode == BlendDifference)   return abs(base - blend);
        if (mode == BlendExclusion)    return base + blend - 2.0 * base * blend;
        return blend;
    }

    /// Blends and then fades back toward the base by `alpha`, which is how every call site uses
    /// it: the effect's strength slider arrives as that last argument.
    vec3 ApplyBlending(int mode, vec3 base, vec3 blend, float alpha) {
        return mix(base, saturate(BlendChannels(mode, base, blend)), saturate(alpha));
    }

    vec3 BlendOpacity(vec3 base, vec3 blend, int mode, float alpha) {
        return ApplyBlending(mode, base, blend, alpha);
    }

    vec3 BlendOpacity(vec3 base, float blend, int mode, float alpha) {
        return ApplyBlending(mode, base, CAST3(blend), alpha);
    }

    #endif
    """

    // MARK: - common_composite.h / common_blur.h

    static let commonComposite = """
    #ifndef DIORAMA_COMMON_COMPOSITE_H
    #define DIORAMA_COMMON_COMPOSITE_H
    #include "common.h"

    // An effect pass renders the layer it is applied to at the same size as the layer, so a
    // composite is a straight overlay unless a shader says otherwise. `ApplyCompositeOffset`
    // exists for passes that sample a neighbouring texel and is a no-op at this scale.
    vec4 ApplyComposite(vec4 base, vec4 overlay) {
        return vec4(mix(base.rgb, overlay.rgb, overlay.a), max(base.a, overlay.a));
    }

    vec2 ApplyCompositeOffset(vec2 uv, vec2 resolution) { return uv; }

    #endif
    """

    /// Separable Gaussian taps. The weights are the standard binomial ones for each kernel
    /// width, normalised, which is what a blur of that radius is expected to look like.
    static let commonBlur = """
    #ifndef DIORAMA_COMMON_BLUR_H
    #define DIORAMA_COMMON_BLUR_H
    #include "common.h"

    vec4 blur3a(sampler2D tex, vec2 uv, vec2 step) {
        vec4 total = texSample2D(tex, uv) * 0.5;
        total += texSample2D(tex, uv + step) * 0.25;
        total += texSample2D(tex, uv - step) * 0.25;
        return total;
    }

    vec4 blur7a(sampler2D tex, vec2 uv, vec2 step) {
        vec4 total = texSample2D(tex, uv) * 0.3125;
        total += (texSample2D(tex, uv + step) + texSample2D(tex, uv - step)) * 0.234375;
        total += (texSample2D(tex, uv + step * 2.0) + texSample2D(tex, uv - step * 2.0)) * 0.09375;
        total += (texSample2D(tex, uv + step * 3.0) + texSample2D(tex, uv - step * 3.0)) * 0.015625;
        return total;
    }

    vec4 blur13a(sampler2D tex, vec2 uv, vec2 step) {
        vec4 total = texSample2D(tex, uv) * 0.1964825501511404;
        total += (texSample2D(tex, uv + step * 1.411764705882353)
                  + texSample2D(tex, uv - step * 1.411764705882353)) * 0.2969069646728344;
        total += (texSample2D(tex, uv + step * 3.2941176470588234)
                  + texSample2D(tex, uv - step * 3.2941176470588234)) * 0.09447039785044732;
        total += (texSample2D(tex, uv + step * 5.176470588235294)
                  + texSample2D(tex, uv - step * 5.176470588235294)) * 0.010381362401148057;
        return total;
    }

    #endif
    """
}
