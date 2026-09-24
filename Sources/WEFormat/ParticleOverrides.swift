import Foundation
import simd

/// Per-instance tuning a scene object applies to the particle preset it uses.
///
/// Wallpaper Engine keeps one definition — `fireflies.json`, `ember.json` — and lets every
/// object that places it scale the result: fewer of them, dimmer, larger, slower, a different
/// colour. `scene.json` writes that as `instanceoverride`, and in a real library of 114
/// wallpapers a third of every particle object carries one.
///
/// Ignoring them runs each instance at the preset's own settings, which is not a subtle
/// difference: one scene's twelve emitters came out at full brightness and full rate where the
/// author had asked for a fifth of the alpha, and buried the wallpaper under its own confetti.
///
/// Every field but the colour is a multiplier, which is what the observed values say — rates
/// from 0.1 to 2.7, alphas from 0.2 to 0.67, sizes from 0.53 to 5, all clustered around 1.
public struct ParticleOverrides: Sendable, Hashable, Codable {
    public var alpha: Float?
    public var rate: Float?
    /// Scales how many particles may be alive at once.
    public var count: Float?
    public var lifetime: Float?
    public var size: Float?
    /// Scales the speed particles are launched at.
    public var speed: Float?
    /// An outright replacement rather than a multiplier, as 0...1 components.
    public var color: SIMD3<Float>?

    public static let none = ParticleOverrides()

    public init(
        alpha: Float? = nil, rate: Float? = nil, count: Float? = nil, lifetime: Float? = nil,
        size: Float? = nil, speed: Float? = nil, color: SIMD3<Float>? = nil
    ) {
        self.alpha = alpha
        self.rate = rate
        self.count = count
        self.lifetime = lifetime
        self.size = size
        self.speed = speed
        self.color = color
    }

    public var isEmpty: Bool {
        alpha == nil && rate == nil && count == nil && lifetime == nil
            && size == nil && speed == nil && color == nil
    }

    public init(from decoder: Decoder) throws {
        let object = try CaseInsensitiveContainer(from: decoder)

        // Negative or non-finite multipliers are dropped rather than clamped: content is
        // untrusted, and a negative rate or lifetime has no meaning to fall back to.
        func multiplier(_ name: String) -> Float? {
            guard let value = object.double(name), value.isFinite, value >= 0 else { return nil }
            return Float(value)
        }

        alpha = multiplier("alpha")
        rate = multiplier("rate")
        count = multiplier("count")
        lifetime = multiplier("lifetime")
        size = multiplier("size")
        speed = multiplier("speed")

        // `colorn` is already 0...1; `color` is the 0...255 spelling used elsewhere in the
        // format. Both appear in content.
        if let normalized = object.value(WEVector3.self, "colorn") {
            color = SIMD3(Float(normalized.x), Float(normalized.y), Float(normalized.z))
        } else if let raw = object.value(WEVector3.self, "color") {
            color = SIMD3(Float(raw.x), Float(raw.y), Float(raw.z)) / 255
        }
    }
}
