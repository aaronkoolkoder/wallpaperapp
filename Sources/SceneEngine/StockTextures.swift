import Metal
import simd

/// Diorama's own versions of the utility textures Wallpaper Engine ships with itself.
///
/// Stock effects name these as defaults — `util/noise`, `util/noflow`, `util/clouds_256`,
/// `util/white`, `util/black` — and no wallpaper package carries them, because every copy of
/// Wallpaper Engine already has them. Without them each one bound the renderer's white
/// placeholder, which is right for `util/white` by coincidence and wrong for everything else:
/// a flow map reads white as full-strength diagonal motion, and noise that is white everywhere
/// is no noise at all.
///
/// These are generated here, procedurally, from what the shaders that sample them require —
/// nothing is copied from Wallpaper Engine. They need to *behave* the same, not to be the
/// same pixels: noise has to be uniformly distributed and tile, clouds soft and tileable, and
/// a neutral flow map has to read as no motion.
enum StockTextures {
    /// The names this can supply, without the `.tex` a reference sometimes carries.
    static let names: Set<String> = [
        "util/white", "util/black", "util/noflow", "util/noise", "util/clouds_256",
    ]

    /// The stock texture a reference means, or nil when it is not one of them.
    static func name(for reference: String) -> String? {
        var name = reference.replacingOccurrences(of: "\\", with: "/").lowercased()
        if name.hasPrefix("materials/") { name.removeFirst("materials/".count) }
        if name.hasSuffix(".tex") { name.removeLast(".tex".count) }
        if names.contains(name) { return name }
        return particleSprite(for: name)
    }

    /// Stand-ins for Wallpaper Engine's stock particle sprites.
    ///
    /// Emitters name `particle/halo`, `particle/fog/fog1`, `particle/nature/leaves7` and their
    /// numbered variants, which ship with Wallpaper Engine rather than the wallpaper — in a real
    /// library of 114 they were missing from 10, 10 and 4 wallpapers respectively, and every one
    /// of those particles drew as a hard white square before any of this existed.
    ///
    /// Each family gets the silhouette its name describes rather than one soft blob for all of
    /// them. The blob was enough while everything using it glowed, and visibly not enough
    /// afterwards: an autumn wallpaper's falling leaves came out as pale smudges that all but
    /// vanished against a bright sky, where the author's preview shows leaf-shaped leaves.
    /// Shape is most of what a particle sprite contributes — emitters tint it themselves.
    static func particleSprite(for name: String) -> String? {
        guard name.hasPrefix("particle/") else { return nil }
        if name.contains("leaf") || name.contains("leaves") {
            // The number in `leaves1` … `leaves7` picks the colour, so a wallpaper drifting two
            // kinds of leaf past each other gets two kinds rather than the same one twice.
            return "particle:leaf\(variantNumber(in: name))"
        }
        if name.contains("petal") || name.contains("sakura") || name.contains("blossom") {
            return "particle:petal"
        }
        if name.contains("fog") || name.contains("smoke") || name.contains("cloud") {
            return "particle:fog"
        }
        if name.contains("drop") || name.contains("rain") { return "particle:drop" }
        if name.contains("beam") || name.contains("ray") || name.contains("shaft") {
            return "particle:beam"
        }
        if name.contains("lightning") || name.contains("bolt") { return "particle:bolt" }
        if name.contains("debris") || name.contains("rubble") { return "particle:debris" }
        if name.contains("wave") || name.contains("ripple") || name.contains("ring") {
            return "particle:ring"
        }
        if name.contains("flare") || name.contains("star") { return "particle:flare" }
        return "particle:glow"
    }

    /// Whether a stock name is an approximation rather than a faithful equivalent, so the
    /// compatibility report can say so.
    static func isApproximation(_ name: String) -> Bool { name.hasPrefix("particle:") }

    /// What an approximation draws, for the compatibility report to name. "Drawn with a
    /// built-in sprite" leaves the reader to guess whether their leaves are leaves.
    static func approximation(of name: String) -> String? {
        guard isApproximation(name) else { return nil }
        return String(name.dropFirst("particle:".count).prefix { !$0.isNumber })
    }

    /// The trailing number in a texture's name, or 0 — `leaves7` is 7, `rosepetals` is 0.
    static func variantNumber(in name: String) -> Int {
        Int(String(name.reversed().prefix(while: \.isNumber).reversed())) ?? 0
    }

    static func make(_ name: String, device: any MTLDevice) -> SceneTexture? {
        if name.hasPrefix("particle:leaf") {
            let variant = Int(name.dropFirst("particle:leaf".count)) ?? 0
            return image(
                sprite(side: 64, colour: leafColours[variant % leafColours.count], shape: leaf),
                side: 64, device: device, label: name, repeats: false
            )
        }
        switch name {
        case "util/white": return solid(255, 255, 255, 255, device: device, label: name)
        case "util/black": return solid(0, 0, 0, 255, device: device, label: name)
        // Flow maps are read as `(rg - 0.498) * 2`, so 127 is the value that means "still".
        case "util/noflow": return solid(127, 127, 127, 255, device: device, label: name)
        case "util/noise": return image(noise(side: 256), side: 256, device: device, label: name)
        case "util/clouds_256": return image(clouds(side: 256), side: 256, device: device, label: name)
        case "particle:glow":
            return image(sprite(side: 64) { x, y in falloff(x * x + y * y, sharpness: 3) },
                         side: 64, device: device, label: name, repeats: false)
        case "particle:fog":
            return image(fog(side: 128), side: 128, device: device, label: name, repeats: false)
        case "particle:drop":
            return image(sprite(side: 64) { x, y in falloff(x * x * 36 + y * y, sharpness: 3) },
                         side: 64, device: device, label: name, repeats: false)
        case "particle:beam":
            return image(sprite(side: 64) { x, y in falloff(x * x * 9, sharpness: 3) * (1 - abs(y)) },
                         side: 64, device: device, label: name, repeats: false)
        case "particle:leaf":
            return image(sprite(side: 64, shape: leaf), side: 64, device: device,
                         label: name, repeats: false)
        case "particle:petal":
            return image(sprite(side: 64, colour: petalColour, shape: petal), side: 64,
                         device: device, label: name, repeats: false)
        case "particle:debris":
            return image(sprite(side: 32, shape: debris), side: 32,
                         device: device, label: name, repeats: false)
        case "particle:bolt":
            return image(sprite(side: 64, shape: bolt), side: 64, device: device,
                         label: name, repeats: false)
        case "particle:ring":
            return image(sprite(side: 64, shape: ring), side: 64, device: device,
                         label: name, repeats: false)
        case "particle:flare":
            return image(sprite(side: 64, shape: flare), side: 64, device: device,
                         label: name, repeats: false)
        default: return nil
        }
    }

    // MARK: - Particle silhouettes
    //
    // Each takes a point over -1...1 in both axes and answers how opaque the sprite is there.
    // Solid in the middle with a soft edge, rather than a glow that fades all the way out: a
    // leaf is an object, and one drawn as a gradient disappears against a bright sky.

    /// A leaf: widest below the middle, drawn to a point at the tip, with a stem.
    static func leaf(_ x: Float, _ y: Float) -> Float {
        let along = (y + 1) / 2
        guard along > 0, along < 1 else { return 0 }
        let halfWidth = 0.58 * sinf(.pi * powf(along, 0.78)) * (1 - 0.3 * along * along)
        let blade = 1 - smoothstep(halfWidth - 0.05, halfWidth + 0.05, abs(x))
        // The stem is what makes it read as a leaf at the dozen pixels across an emitter
        // actually draws it at, rather than as a seed or a flake.
        let stem = along < 0.2 ? 1 - smoothstep(0.015, 0.05, abs(x)) : 0
        return max(blade, stem)
    }

    /// A petal: rounder than a leaf and widest near the tip, the way a rose or blossom petal is.
    static func petal(_ x: Float, _ y: Float) -> Float {
        let along = (y + 1) / 2
        guard along > 0, along < 1 else { return 0 }
        let halfWidth = 0.72 * sinf(.pi * powf(along, 1.4))
        return 1 - smoothstep(halfWidth - 0.06, halfWidth + 0.06, abs(x))
    }

    /// A chip of debris: angular and off-round, so a burst of them does not read as a burst of
    /// circles.
    static func debris(_ x: Float, _ y: Float) -> Float {
        let angle = atan2f(y, x)
        let radius = 0.62 + 0.16 * cosf(3 * angle + 0.7) + 0.08 * cosf(5 * angle - 1.1)
        return 1 - smoothstep(radius - 0.06, radius + 0.06, sqrtf(x * x + y * y))
    }

    /// A bolt: one jagged streak down the sprite, fading out at both ends.
    static func bolt(_ x: Float, _ y: Float) -> Float {
        // A fixed zigzag rather than a random one. An emitter has a single texture to draw
        // every bolt from, so they are all this shape, rotated and scaled.
        let path = 0.38 * sinf(2.9 * y + 1.1) * (1 - abs(y) * 0.35)
        let core = 1 - smoothstep(0.03, 0.13, abs(x - path))
        return core * (1 - smoothstep(0.72, 1, abs(y)))
    }

    /// A ring: a ripple's edge, open in the middle.
    static func ring(_ x: Float, _ y: Float) -> Float {
        let distance = sqrtf(x * x + y * y)
        return (1 - smoothstep(0, 0.24, abs(distance - 0.72))) * (1 - smoothstep(0.88, 1, distance))
    }

    /// A flare: a bright core with four rays out of it.
    static func flare(_ x: Float, _ y: Float) -> Float {
        let core = falloff(x * x + y * y, sharpness: 4)
        let across = falloff(min(1, x * x * 1.1 + y * y * 90), sharpness: 2)
        let down = falloff(min(1, y * y * 1.1 + x * x * 90), sharpness: 2)
        return min(1, core + 0.75 * max(across, down))
    }

    /// Fog: a soft blob broken up by cloud noise.
    ///
    /// Fog and smoke emitters stack dozens of these on top of each other. A perfectly smooth
    /// disc of haze stacks into something that reads as bubbles; noise across it stacks into
    /// something that reads as fog.
    static func fog(side: Int) -> [UInt8] {
        let field = cloudsField(side: side)
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for row in 0 ..< side {
            for column in 0 ..< side {
                let x = (Float(column) + 0.5) / Float(side) * 2 - 1
                let y = (Float(row) + 0.5) / Float(side) * 2 - 1
                let shape = 0.8 * falloff(x * x + y * y, sharpness: 1.6)
                let value = shape * (0.35 + 0.95 * field[row * side + column])
                pixels[(row * side + column) * 4 + 3] = UInt8((min(max(value, 0), 1) * 255).rounded())
            }
        }
        return pixels
    }

    private static func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        guard high > low else { return value < low ? 0 : 1 }
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Colours for the sprites that are objects rather than light.
    ///
    /// Wallpaper Engine's own sprite carries its colour — its leaves are brown because the
    /// texture is brown — and an emitter that wants them unchanged asks for white. A white
    /// stand-in therefore comes out white, which is how an autumn wallpaper's leaves ended up
    /// invisible against its bright sky. Light does not have this problem: a glow, a beam or a
    /// bolt is white in the texture too, and the emitter's colour is the whole point.
    static let leafColours: [SIMD3<UInt8>] = [
        SIMD3(150, 84, 36),     // brown
        SIMD3(198, 124, 42),    // orange
        SIMD3(176, 146, 62),    // gold
        SIMD3(170, 66, 44),     // red
    ]
    static let petalColour = SIMD3<UInt8>(242, 158, 178)

    // Debris is not on this list, though it is an object too: the emitters that use it say what
    // colour it is — the ash over a burning city tints it to a warm grey — so a grey sprite
    // under a grey tint came out almost black.

    /// `colour`, with alpha from `shape` over -1...1 in both axes. Straight alpha, like every
    /// other texture here: the shaders premultiply after sampling.
    static func sprite(
        side: Int,
        colour: SIMD3<UInt8> = SIMD3(255, 255, 255),
        shape: (Float, Float) -> Float
    ) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for row in 0 ..< side {
            for column in 0 ..< side {
                let x = (Float(column) + 0.5) / Float(side) * 2 - 1
                let y = (Float(row) + 0.5) / Float(side) * 2 - 1
                let alpha = min(max(shape(x, y), 0), 1)
                let offset = (row * side + column) * 4
                pixels[offset] = colour.x
                pixels[offset + 1] = colour.y
                pixels[offset + 2] = colour.z
                pixels[offset + 3] = UInt8((alpha * 255).rounded())
            }
        }
        return pixels
    }

    /// 1 at the centre, 0 at a squared distance of 1 and beyond, smooth between.
    private static func falloff(_ squaredDistance: Float, sharpness: Float) -> Float {
        guard squaredDistance < 1 else { return 0 }
        return powf(1 - squaredDistance, sharpness)
    }

    // MARK: - Generation

    /// Independent, uniformly distributed values in every channel. Film grain multiplies two
    /// lookups of it and foliage sway takes a phase from it, so what matters is that it is
    /// uniform, uncorrelated between channels, and tiles — which independent texels trivially
    /// do.
    static func noise(side: Int) -> [UInt8] {
        var random = SplitMix64(seed: 0xD10_2A_0A15E)
        return (0 ..< side * side * 4).map { _ in UInt8(truncatingIfNeeded: random.next() >> 56) }
    }

    /// Soft, tileable fractal noise in the colour channels, alpha opaque.
    static func clouds(side: Int) -> [UInt8] {
        let field = cloudsField(side: side)
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for index in 0 ..< side * side {
            let value = UInt8(clamping: Int((field[index] * 255).rounded()))
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
        }
        return pixels
    }

    /// The same noise as a field over 0...1, which the fog sprite shapes into a wisp.
    ///
    /// Five octaves of value noise on lattices that divide the texture evenly, so every octave
    /// wraps at the edge and the sum tiles with no seam.
    static func cloudsField(side: Int) -> [Float] {
        var random = SplitMix64(seed: 0xC10_0D5)
        var field = [Float](repeating: 0, count: side * side)
        var amplitude: Float = 1
        var total: Float = 0

        for octave in 0 ..< 5 {
            let cells = 4 << octave
            let lattice = (0 ..< cells * cells).map { _ in Float(random.next() >> 40) / Float(1 << 24) }
            let step = Float(side) / Float(cells)
            for y in 0 ..< side {
                for x in 0 ..< side {
                    let fx = Float(x) / step, fy = Float(y) / step
                    let x0 = Int(fx) % cells, y0 = Int(fy) % cells
                    let x1 = (x0 + 1) % cells, y1 = (y0 + 1) % cells
                    // Smoothstep weights, so the lattice does not show as creases.
                    let tx = smooth(fx - fx.rounded(.down)), ty = smooth(fy - fy.rounded(.down))
                    let top = mix(lattice[y0 * cells + x0], lattice[y0 * cells + x1], tx)
                    let bottom = mix(lattice[y1 * cells + x0], lattice[y1 * cells + x1], tx)
                    field[y * side + x] += mix(top, bottom, ty) * amplitude
                }
            }
            total += amplitude
            amplitude *= 0.5
        }

        guard total > 0 else { return field }
        for index in 0 ..< field.count { field[index] /= total }
        return field
    }

    private static func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }
    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    // MARK: - Upload

    private static func solid(
        _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8, device: any MTLDevice, label: String
    ) -> SceneTexture? {
        image([r, g, b, a], side: 1, device: device, label: label)
    }

    private static func image(
        _ rgba: [UInt8], side: Int, device: any MTLDevice, label: String, repeats: Bool = true
    ) -> SceneTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        rgba.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: side * 4
            )
        }
        texture.label = "stock:\(label)"
        // The utility textures repeat: the noise ones are sampled far outside 0..1 on purpose,
        // and for the one-texel ones the question does not arise. A sprite must not.
        return SceneTexture(texture: texture, imageSize: SIMD2(Float(side), Float(side)), repeats: repeats)
    }
}

/// A small, fast, well-distributed PRNG, seeded so the stock textures are the same every run
/// and every wallpaper looks the same from one launch to the next.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
