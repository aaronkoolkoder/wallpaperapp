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
