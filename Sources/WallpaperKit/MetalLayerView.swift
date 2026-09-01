import AppKit
import QuartzCore

/// A layer-backed view whose backing layer is a `CAMetalLayer`.
///
/// Deliberately minimal: it owns no rendering logic. The render loop lives on its own serial
/// queue and only ever touches the layer's drawable, so this class exists purely to get a
/// correctly-configured `CAMetalLayer` into the view hierarchy and to keep its `drawableSize`
/// in step with the backing store when the display or its scale factor changes.
public final class MetalLayerView: NSView {
    /// Fired when the drawable size changes, so the renderer can resize its targets.
    public var onDrawableSizeChange: ((CGSize) -> Void)?

    /// Render at a fraction of native resolution and let the compositor scale up. On a 5K
    /// display this is a large GPU saving for content nobody inspects at 1:1 (PLAN.md §6.2).
    public var resolutionScale: Double = 1.0 {
        didSet { if resolutionScale != oldValue { updateDrawableSize() } }
    }

    public override var wantsUpdateLayer: Bool { true }
    public override var isOpaque: Bool { true }
    public override var isFlipped: Bool { true }

    public var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used; this view is never loaded from a nib") }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.needsDisplayOnBoundsChange = true
        // Two drawables, not three. A wallpaper is not latency-sensitive and does not need the
        // extra buffered frame; double buffering saves a full framebuffer of memory per display,
        // which matters when this process is resident 24/7 across several 5K displays.
        layer.maximumDrawableCount = 2
        layer.presentsWithTransaction = false
        // HDR costs bandwidth and power for no benefit on content that is not mastered for it.
        layer.wantsExtendedDynamicRangeContent = false
        return layer
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer, let window else { return }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale

        let native = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let clamped = max(0.25, min(1.0, resolutionScale))
        let target = CGSize(
            width: (native.width * clamped).rounded(.down),
            height: (native.height * clamped).rounded(.down)
        )
        guard target.width >= 1, target.height >= 1, target != metalLayer.drawableSize else { return }

        metalLayer.drawableSize = target
        onDrawableSizeChange?(target)
    }
}
