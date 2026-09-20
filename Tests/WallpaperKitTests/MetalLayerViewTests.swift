import AppKit
import Metal
import QuartzCore
import Testing
@testable import WallpaperKit

@Suite("MetalLayerView")
@MainActor
struct MetalLayerViewTests {

    @Test("The backing layer is given a GPU to vend drawables from")
    func layerHasADevice() throws {
        // A CAMetalLayer with no `device` returns nil from `nextDrawable()` every single time,
        // silently. That meant scenes never drew a frame to the desktop at all — reported as
        // "none of the scenes work, only the videos", because videos use no Metal layer.
        //
        // Offscreen rendering could not catch it: that path makes its own texture and never
        // touches a CAMetalLayer, so every render test passed while the app showed black.
        let view = MetalLayerView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let layer = try #require(view.metalLayer)
        #expect(layer.device != nil)
    }

    @Test("An explicit device is the one the layer uses")
    func honoursExplicitDevice() throws {
        // It must be the same GPU the renderer draws with; a drawable from one device used
        // against another's command queue is undefined.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let view = MetalLayerView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        view.metalDevice = device

        let layer = try #require(view.metalLayer)
        #expect(layer.device === device)
    }

    @Test("A device set before the layer exists still reaches it")
    func deviceSurvivesLazyLayerCreation() throws {
        // `makeBackingLayer` is called lazily, so the assignment has to work in either order.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let view = MetalLayerView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        view.metalDevice = device
        #expect(view.metalLayer?.device === device)
    }
}
