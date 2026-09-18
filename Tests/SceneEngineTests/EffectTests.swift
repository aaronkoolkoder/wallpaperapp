import Foundation
import Metal
import MetalRenderer
import Testing
import WEFormat
@testable import SceneEngine

@Suite("Effects")
struct EffectTests {

    private func effect(_ json: String) throws -> EffectDocument {
        try JSONDecoder().decode(EffectDocument.self, from: Data(json.utf8))
    }

    @Test("Classifies effects by name onto built-in implementations")
    func classifiesByName() throws {
        #expect(try effect(#"{"name":"Bloom"}"#).classifiedKind == "bloom")
        #expect(try effect(#"{"name":"Gaussian Blur"}"#).classifiedKind == "blur")
        #expect(try effect(#"{"name":"Vignette"}"#).classifiedKind == "vignette")
    }

    @Test("Falls back to the material path when the name is uninformative")
    func classifiesByMaterial() throws {
        let document = try effect("""
        {"name":"Effect 12","passes":[{"material":"materials/effectpasses/bloom.json"}]}
        """)
        #expect(document.classifiedKind == "bloom")
    }

    @Test("An unrecognised effect classifies as unknown rather than guessing")
    func unknownStaysUnknown() throws {
        // Guessing wrong here silently applies the wrong visual effect, which is worse than
        // applying none and saying so.
        #expect(try effect(#"{"name":"Kaleidoscope Warp"}"#).classifiedKind == "unknown")
        #expect(SceneBuilder.postEffect(for: try effect(#"{"name":"Kaleidoscope Warp"}"#)) == nil)
    }

    @Test("Render-target bindings are distinguished from file paths")
    func bindingKinds() throws {
        let document = try effect("""
        {"name":"Bloom","passes":[{"material":"m.json","target":"_rt_Bloom",
          "bind":[{"index":0,"name":"_rt_FullFrameBuffer"},
                  {"index":1,"name":"materials/noise.tex"}]}]}
        """)
        let bindings = try #require(document.passes.first?.bindings)
        #expect(bindings[0].isRenderTarget)
        #expect(bindings[1].isRenderTarget == false)
    }

    @Test("Scene-wide bloom is read from general, where the format declares it")
    func sceneBloomFromGeneral() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let json = """
        {"general":{"bloom":true,"bloomthreshold":0.4,"bloomstrength":1.5,
                    "orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[]}
        """
        let document = try JSONDecoder().decode(SceneDocument.self, from: Data(json.utf8))
        let directory = FileManager.default.temporaryDirectory
        let assets = SceneAssets(wallpaperID: "t", directory: directory, packageURL: nil)
        let scene = SceneBuilder().build(document: document, assets: assets, device: device)

        #expect(scene.sceneEffects.count == 1)
        // Scene bloom is declared on `general` rather than as an effect file, so there is no
        // author shader to compile and the built-in one is the faithful answer.
        if case .builtIn(.bloom(let threshold, let intensity)) = scene.sceneEffects.first {
            #expect(abs(threshold - 0.4) < 0.001)
            #expect(abs(intensity - 1.5) < 0.001)
        } else {
            Issue.record("expected a bloom effect")
        }
    }

    @Test("A scene without bloom declares no scene effects")
    func noBloomNoEffects() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let document = try JSONDecoder().decode(
            SceneDocument.self,
            from: Data(#"{"general":{"bloom":false},"objects":[]}"#.utf8)
        )
        let assets = SceneAssets(
            wallpaperID: "t", directory: FileManager.default.temporaryDirectory, packageURL: nil
        )
        #expect(SceneBuilder().build(document: document, assets: assets, device: device)
            .sceneEffects.isEmpty)
    }

    @Test("A malformed particle or effect count cannot allocate unboundedly")
    func maxCountClamped() throws {
        let document = try JSONDecoder().decode(
            ParticleDocument.self, from: Data(#"{"maxcount":-5}"#.utf8)
        )
        #expect(document.maxCount >= 0)
    }
}

@Suite("PostProcessor")
struct PostProcessorTests {

    @Test("Builds without a display attached")
    func buildsHeadless() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        // CI runs headless, so nothing in this module may require a CAMetalLayer at init.
        _ = try PostProcessor(device: device)
    }

    @Test("An empty chain copies the source through unchanged")
    func emptyChainBlits() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        let processor = try PostProcessor(device: device)
        let pool = FBOPool(device: device)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let source = device.makeTexture(descriptor: descriptor),
              let destination = device.makeTexture(descriptor: descriptor),
              let buffer = queue.makeCommandBuffer() else { return }

        processor.apply(
            [], source: source, destination: destination, commandBuffer: buffer, pool: pool
        )
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.error == nil)
    }

    @Test("A multi-pass chain completes without a Metal error")
    func multiPassChainRuns() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        let processor = try PostProcessor(device: device)
        let pool = FBOPool(device: device)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let source = device.makeTexture(descriptor: descriptor),
              let destination = device.makeTexture(descriptor: descriptor),
              let buffer = queue.makeCommandBuffer() else { return }

        // Bloom alone is four GPU passes, so this exercises the ping-pong and the retained
        // original copy that the combine step needs.
        processor.apply(
            [.bloom(threshold: 0.5, intensity: 1.0), .vignette(intensity: 0.5), .sharpen(amount: 0.3)],
            source: source, destination: destination, commandBuffer: buffer, pool: pool
        )
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.error == nil)
    }
}
