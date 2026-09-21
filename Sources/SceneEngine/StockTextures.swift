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
        return names.contains(name) ? name : nil
    }

    static func make(_ name: String, device: any MTLDevice) -> SceneTexture? {
        switch name {
        case "util/white": return solid(255, 255, 255, 255, device: device, label: name)
        case "util/black": return solid(0, 0, 0, 255, device: device, label: name)
        // Flow maps are read as `(rg - 0.498) * 2`, so 127 is the value that means "still".
        case "util/noflow": return solid(127, 127, 127, 255, device: device, label: name)
        case "util/noise": return image(noise(side: 256), side: 256, device: device, label: name)
        case "util/clouds_256": return image(clouds(side: 256), side: 256, device: device, label: name)
        default: return nil
        }
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

    /// Soft, tileable fractal noise in the colour channels, alpha opaque. Five octaves of value
    /// noise on lattices that divide the texture evenly, so every octave wraps at the edge and
    /// the sum tiles with no seam.
    static func clouds(side: Int) -> [UInt8] {
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

        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for index in 0 ..< side * side {
            let value = UInt8(clamping: Int((field[index] / total * 255).rounded()))
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
        }
        return pixels
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
        _ rgba: [UInt8], side: Int, device: any MTLDevice, label: String
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
        // Every stock texture repeats. The noise ones are sampled far outside 0..1 on purpose,
        // and for the one-texel ones the question does not arise.
        return SceneTexture(texture: texture, imageSize: SIMD2(Float(side), Float(side)), repeats: true)
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
