import Metal
import WEFormat
import simd

/// An animated texture's frames, ready to step through.
///
/// Wallpaper Engine stores a GIF as one or more atlas pages plus a table of where each frame
/// sits. Drawing a page as it is shows every frame at once, as a grid — which is what every
/// animated layer and bird flock in a real library looked like until this existed.
public struct SpriteAnimation: @unchecked Sendable {
    public struct Frame: Sendable, Hashable {
        /// Index into ``SpriteAnimation/pages``.
        public var page: Int
        /// The frame within its page, as (u0, v0, u1, v1).
        public var uvRect: SIMD4<Float>
        /// Seconds.
        public var duration: Float
    }

    public let pages: [any MTLTexture]
    public let frames: [Frame]
    /// Seconds for one pass through every frame.
    public let loopDuration: Float
    /// Pixel size of the first frame, which is what a layer with no stated size is drawn at.
    public let frameSize: SIMD2<Float>

    /// Frames whose page is missing or whose rectangle is empty are dropped; nil if none remain.
    public init?(sheet: SpriteSheet, pages: [any MTLTexture]) {
        guard !pages.isEmpty else { return nil }
        var frames: [Frame] = []
        frames.reserveCapacity(sheet.frames.count)
        var frameSize: SIMD2<Float>?

        for frame in sheet.frames {
            guard pages.indices.contains(frame.imageIndex),
                  frame.width > 0, frame.height > 0,
                  frame.x.isFinite, frame.y.isFinite
            else { continue }
            let page = pages[frame.imageIndex]
            let width = Float(page.width), height = Float(page.height)
            frames.append(
                Frame(
                    page: frame.imageIndex,
                    uvRect: SIMD4(
                        frame.x / width, frame.y / height,
                        (frame.x + frame.width) / width, (frame.y + frame.height) / height
                    ),
                    // A zero or nonsense duration would stall the loop on one frame; GIFs that
                    // do this play at 10fps in browsers, so that is what they get here.
                    duration: frame.duration.isFinite && frame.duration > 0 ? frame.duration : 0.1
                )
            )
            if frameSize == nil { frameSize = SIMD2(frame.width, frame.height) }
        }
        guard !frames.isEmpty, let frameSize else { return nil }

        self.pages = pages
        self.frames = frames
        self.frameSize = frameSize
        loopDuration = frames.reduce(0) { $0 + $1.duration }
    }

    /// The frame showing `time` seconds into the animation, looping.
    public func frame(at time: Float) -> Frame {
        guard frames.count > 1, loopDuration > 0, time.isFinite else { return frames[0] }
        var remaining = time.truncatingRemainder(dividingBy: loopDuration)
        if remaining < 0 { remaining += loopDuration }
        for frame in frames {
            if remaining < frame.duration { return frame }
            remaining -= frame.duration
        }
        return frames[frames.count - 1]
    }

    /// The texture a frame samples from.
    public func texture(for frame: Frame) -> any MTLTexture { pages[frame.page] }
}
