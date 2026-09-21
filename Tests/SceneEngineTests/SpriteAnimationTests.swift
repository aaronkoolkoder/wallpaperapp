import Foundation
import Metal
import Testing
import WEFormat
import simd
@testable import SceneEngine

@Suite("Animated textures")
struct SpriteAnimationTests {

    private func page(_ device: any MTLDevice, _ width: Int, _ height: Int) -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        return device.makeTexture(descriptor: descriptor)!
    }

    @Test("A frame's rectangle becomes UVs within its own page")
    func uvRects() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        // A real strip: 3072x896 frames stacked in a 4096x4096 atlas.
        let sheet = SpriteSheet(version: "TEXS0002", frames: [
            SpriteFrame(imageIndex: 0, duration: 0.1, x: 0, y: 0, width: 3072, height: 896),
            SpriteFrame(imageIndex: 0, duration: 0.1, x: 0, y: 896, width: 3072, height: 896),
        ])
        let animation = try #require(SpriteAnimation(sheet: sheet, pages: [page(device, 4096, 4096)]))
        #expect(animation.frames[1].uvRect == SIMD4(0, 0.21875, 0.75, 0.4375))
        #expect(animation.frameSize == SIMD2(3072, 896))
    }

    @Test("Frames advance by their own durations and loop")
    func timing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let frames = (0 ..< 4).map {
            SpriteFrame(imageIndex: 0, duration: 0.1, x: Float($0) * 2, y: 0, width: 2, height: 2)
        }
        let animation = try #require(
            SpriteAnimation(sheet: SpriteSheet(version: "TEXS0002", frames: frames), pages: [page(device, 8, 2)])
        )
        func index(at time: Float) -> Int {
            animation.frames.firstIndex(of: animation.frame(at: time))!
        }
        #expect(index(at: 0) == 0)
        #expect(index(at: 0.15) == 1)
        #expect(index(at: 0.39) == 3)
        #expect(index(at: 0.41) == 0)
        #expect(index(at: -0.05) == 3)
        #expect(abs(animation.loopDuration - 0.4) < 0.0001)
    }

    @Test("Frames on a page that does not exist, or with no area, are dropped")
    func invalidFrames() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let sheet = SpriteSheet(version: "TEXS0003", frames: [
            SpriteFrame(imageIndex: 3, duration: 0.1, x: 0, y: 0, width: 2, height: 2),
            SpriteFrame(imageIndex: 0, duration: 0.1, x: 0, y: 0, width: 0, height: 2),
            SpriteFrame(imageIndex: 0, duration: 0, x: 2, y: 0, width: 2, height: 2),
        ])
        let animation = try #require(SpriteAnimation(sheet: sheet, pages: [page(device, 4, 2)]))
        #expect(animation.frames.count == 1)
        // A zero duration would pin the loop to one frame.
        #expect(animation.frames[0].duration == 0.1)

        let empty = SpriteSheet(version: "TEXS0003", frames: [
            SpriteFrame(imageIndex: 1, duration: 0.1, x: 0, y: 0, width: 2, height: 2),
        ])
        #expect(SpriteAnimation(sheet: empty, pages: [page(device, 4, 2)]) == nil)
    }

    // MARK: - Through the scene builder

    /// A two-page 4x4 animation with one 2x2 frame on each page, as a `.tex` file.
    private static func animatedTexture() -> Data {
        var data = Data()
        func magic(_ text: String) { data.append(contentsOf: Array(text.utf8) + [0]) }
        func int(_ value: Int32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func float(_ value: Float) { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }

        magic("TEXV0005"); magic("TEXI0001")
        int(0); int(4 | 2)                   // RGBA8888; isGif + clampUVs
        int(4); int(4); int(4); int(4); int(0)
        magic("TEXB0003")
        int(2); int(-1)                       // two images, raw pixels
        for fill: UInt8 in [0x40, 0xC0] {
            int(1)                            // one mip level
            int(4); int(4); int(0); int(64); int(64)
            data.append(contentsOf: [UInt8](repeating: fill, count: 64))
        }
        magic("TEXS0003")
        int(2); int(2); int(2)                // two frames of a 2x2 GIF
        for (image, x) in [(Int32(0), Float(0)), (Int32(1), Float(2))] {
            int(image); float(0.25)
            float(x); float(2); float(2); float(0); float(0); float(2)
        }
        return data
    }

    @Test("An animated layer is sized to one frame and shows one frame, not the atlas")
    func builtLayer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diorama-sprite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files: [String: Data] = [
            "models/anim.json": Data(#"{"material": "materials/anim.json"}"#.utf8),
            "materials/anim.json": Data(#"{"passes": [{"shader": "genericimage2", "blending": "translucent", "textures": ["anim"]}]}"#.utf8),
            "materials/anim.tex": Self.animatedTexture(),
            "models/broken.json": Data(#"{"material": "materials/broken.json"}"#.utf8),
            "materials/broken.json": Data(#"{"passes": [{"shader": "genericimage2", "textures": ["nothere"]}]}"#.utf8),
        ]
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        let document = try JSONDecoder().decode(SceneDocument.self, from: Data("""
        {"objects": [
          {"id": 1, "name": "Animated", "image": "models/anim.json", "origin": "0 0 0"},
          {"id": 2, "name": "Broken", "image": "models/broken.json", "origin": "0 0 0"}
        ]}
        """.utf8))

        let assets = SceneAssets(wallpaperID: "sprite", directory: root, packageURL: nil)
        let scene = SceneBuilder().build(document: document, assets: assets, device: device)

        #expect(scene.layers.map(\.name) == ["Animated"])
        let layer = try #require(scene.layers.first)
        let sprite = try #require(layer.sprite)
        #expect(sprite.pages.count == 2)
        #expect(sprite.frames.map(\.page) == [0, 1])
        #expect(layer.size == SIMD2(2, 2))
        #expect(layer.uvRect == SIMD4(0, 0.5, 0.5, 1))

        // The layer whose texture is missing is hidden, and the report says why, rather than
        // drawing a white rectangle over the scene.
        #expect(scene.report.findings.contains {
            $0.feature == "Layer" && ($0.detail ?? "").contains("\"Broken\" is hidden")
        })
    }
}
