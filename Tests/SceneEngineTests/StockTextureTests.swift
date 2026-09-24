import Metal
import Testing
@testable import SceneEngine

/// Diorama's own versions of Wallpaper Engine's `util/*` textures.
@Suite("Stock textures")
struct StockTextureTests {

    @Test("References resolve with or without the folder and extension they are written with")
    func namesResolve() {
        #expect(StockTextures.name(for: "util/noise") == "util/noise")
        #expect(StockTextures.name(for: "materials/util/noflow.tex") == "util/noflow")
        #expect(StockTextures.name(for: "UTIL\\White") == "util/white")
        #expect(StockTextures.name(for: "masks/shake_mask_1") == nil)
    }

    @Test("Noise is spread evenly across the range, in every channel")
    func noiseIsUniform() {
        // Film grain multiplies two lookups of it and foliage sway takes a phase from it; both
        // need values spread evenly, not clustered.
        let pixels = StockTextures.noise(side: 256)
        for channel in 0 ..< 4 {
            let values = stride(from: channel, to: pixels.count, by: 4).map { Double(pixels[$0]) }
            let mean = values.reduce(0, +) / Double(values.count)
            #expect(abs(mean - 127.5) < 3, "channel \(channel) mean \(mean)")
            let low = values.filter { $0 < 64 }.count, high = values.filter { $0 >= 192 }.count
            #expect(abs(Double(low - high)) / Double(values.count) < 0.02)
        }
    }

    @Test("Clouds tile: the texture continues across its own edge")
    func cloudsTile() {
        // Sampled far outside 0..1 and repeated, so a seam at the edge would show as a line
        // across the effect every tile.
        let side = 256
        let pixels = StockTextures.clouds(side: side)
        func value(_ x: Int, _ y: Int) -> Int { Int(pixels[((y % side) * side + (x % side)) * 4]) }

        var seam = 0, interior = 0
        for y in 0 ..< side {
            seam += abs(value(side - 1, y) - value(side, y))        // last column → first
            interior += abs(value(side / 2 - 1, y) - value(side / 2, y))
        }
        // Wrapping across the edge is no rougher than stepping between any two columns.
        #expect(Double(seam) <= Double(interior) * 1.5 + Double(side))
    }

    @Test("A particle sprite is resolved by what its name describes",
          arguments: [
            ("particle/nature/leaves7", "particle:leaf7"),
            ("particle/nature/leaves1", "particle:leaf1"),
            ("particle/nature/rosepetals", "particle:petal"),
            ("particle/fog/fog1", "particle:fog"),
            ("particle/drop", "particle:drop"),
            ("particle/light/light_shafts_0", "particle:beam"),
            ("particle/lightning/lightning3", "particle:bolt"),
            ("particle/debris/debris1", "particle:debris"),
            ("particle/misc/wave", "particle:ring"),
            ("particle/light/flare_1", "particle:flare"),
            ("particle/halo_6", "particle:glow"),
          ])
    func particleNamesResolve(reference: String, expected: String) {
        #expect(StockTextures.name(for: "materials/\(reference).tex") == expected)
        #expect(StockTextures.approximation(of: expected) != nil, "the report should name it")
        // The report names the family, not the numbered variant: "a built-in leaf sprite".
        #expect(StockTextures.approximation(of: expected)?.last?.isNumber != true)
    }

    /// A leaf sprite carries its own colour, because Wallpaper Engine's does: its leaves are
    /// brown because the texture is brown, and an emitter that wants them unchanged asks for
    /// white. A white stand-in comes out white, which is how an autumn wallpaper's falling
    /// leaves ended up invisible against its bright sky.
    @Test("Leaves are leaf-coloured, and two kinds of leaf are two colours")
    func leavesCarryTheirOwnColour() {
        func colour(_ reference: String) -> [UInt8] {
            let name = StockTextures.name(for: reference) ?? ""
            let variant = Int(name.dropFirst("particle:leaf".count)) ?? 0
            let pixels = StockTextures.sprite(
                side: 8, colour: StockTextures.leafColours[variant % StockTextures.leafColours.count]
            ) { _, _ in 1 }
            return Array(pixels.prefix(3))
        }

        let one = colour("particle/nature/leaves1")
        #expect(one != [255, 255, 255], "a white leaf is invisible over a bright sky")
        #expect(one[0] > one[2], "autumn leaves are warm")
        #expect(colour("particle/nature/leaves7") != one, "two kinds of leaf, two colours")
    }

    /// A leaf has to look like one at the dozen pixels across an emitter draws it at: solid in
    /// the middle, taller than it is wide, and pointed at one end. Drawn as a soft round glow —
    /// which every one of these was — falling leaves vanish against a bright sky.
    @Test("A leaf is a solid leaf-shaped silhouette, not a blob")
    func leafIsLeafShaped() {
        #expect(StockTextures.leaf(0, 0) > 0.99, "solid through the middle")
        #expect(StockTextures.leaf(0.9, 0.9) == 0, "and empty in the corners")

        // Pointed at the tip, blunt below the middle: the widest point is in the lower half.
        func width(at y: Float) -> Float {
            Array(stride(from: Float(0), through: 1, by: 0.005))
                .last { StockTextures.leaf($0, y) > 0.5 } ?? 0
        }
        #expect(width(at: 0.9) < width(at: -0.1), "the tip is narrower than the blade")
        #expect(width(at: -0.1) > 0.3 && width(at: -0.1) < 0.7)
        // Taller than wide, or it is a disc with ambitions.
        #expect(width(at: -0.1) * 2 < 1.6)
        // Symmetric across the midrib.
        for y in stride(from: Float(-0.9), through: 0.9, by: 0.3) {
            #expect(abs(StockTextures.leaf(0.3, y) - StockTextures.leaf(-0.3, y)) < 0.001)
        }
    }

    @Test("A ring is open in the middle and a flare has rays")
    func ringAndFlareHaveTheirDefiningFeature() {
        #expect(StockTextures.ring(0, 0) < 0.01, "a ripple is empty in the middle")
        #expect(StockTextures.ring(0.72, 0) > 0.9, "and solid on its edge")

        // Along an axis is brighter than diagonally at the same distance: that is what a ray is.
        let along = StockTextures.flare(0.6, 0)
        let diagonal = StockTextures.flare(0.42, 0.42)
        #expect(along > diagonal + 0.2, "rays: \(along) along vs \(diagonal) diagonal")
    }

    @Test("Fog is soft, uneven, and fades out before its edge")
    func fogIsWispy() {
        // Dozens of these stack on top of each other; a smooth disc of haze stacks into
        // something that reads as bubbles.
        let side = 128
        let pixels = StockTextures.fog(side: side)
        func alpha(_ x: Int, _ y: Int) -> Int { Int(pixels[(y * side + x) * 4 + 3]) }

        #expect(alpha(0, 0) == 0 && alpha(side - 1, side - 1) == 0, "fades out before the edge")

        // Uneven across the middle: a perfectly smooth blob would step by ~1 between neighbours.
        let middle = side / 2
        let steps = (1 ..< side).map { abs(alpha($0, middle) - alpha($0 - 1, middle)) }
        #expect(steps.max() ?? 0 > 4, "no variation across the sprite")
    }

    @Test("A neutral flow map reads as no motion")
    func noflowIsNeutral() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let texture = try #require(StockTextures.make("util/noflow", device: device))
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        // Shake reads a direction as (rg - 0.498) * 2; 127 is what makes that zero.
        #expect(abs((Double(pixel[0]) / 255 - 0.498) * 2) < 0.01)
        #expect(abs((Double(pixel[1]) / 255 - 0.498) * 2) < 0.01)
        #expect(texture.repeats)
    }
}
