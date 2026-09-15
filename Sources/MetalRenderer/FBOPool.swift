import Foundation
import Metal
import os

/// A pooled offscreen render target, returned to its pool when released.
public final class PooledTexture {
    public let texture: any MTLTexture
    let key: FBOPool.BucketKey
    fileprivate weak var pool: FBOPool?
    fileprivate var framesSinceUse: Int = 0

    init(texture: any MTLTexture, key: FBOPool.BucketKey, pool: FBOPool) {
        self.texture = texture
        self.key = key
        self.pool = pool
    }

    public var width: Int { texture.width }
    public var height: Int { texture.height }
}

/// Size-bucketed pool of offscreen render targets.
///
/// Allocating framebuffers per frame is the single easiest way to destroy the performance target
/// in PLAN.md §6: `newTexture` is a driver round trip and, at 4K, a multi-megabyte allocation that
/// the memory system then has to fault in. An effect chain on a busy scene can want a dozen of
/// them per frame, every frame, forever.
///
/// Requests are rounded up to coarse buckets so that near-identical sizes share an allocation.
/// A scene asking for 1920x1080 and 1900x1070 should not hold two full-size targets.
///
/// Not thread-safe by design: this lives on the render queue and is only touched there. Adding a
/// lock would put contention on the frame path to protect against a caller that does not exist.
public final class FBOPool {
    struct BucketKey: Hashable, Sendable {
        let width: Int
        let height: Int
        let pixelFormat: MTLPixelFormat
        let sampleCount: Int
    }

    private let device: any MTLDevice
    private var available: [BucketKey: [PooledTexture]] = [:]
    private var inFlight: [ObjectIdentifier: PooledTexture] = [:]
    private let log = Logger(subsystem: "app.diorama", category: "fbo-pool")

    /// Buckets untouched for this many frames are released. Long enough to survive a wallpaper
    /// switching between two effect configurations, short enough not to hoard 4K targets.
    private let evictionAge: Int
    private let byteBudget: Int

    public private(set) var currentBytes: Int = 0
    public private(set) var peakBytes: Int = 0
    public private(set) var allocationCount: Int = 0
    public private(set) var reuseCount: Int = 0

    public init(device: any MTLDevice, byteBudget: Int = 512 * 1024 * 1024, evictionAge: Int = 120) {
        self.device = device
        self.byteBudget = byteBudget
        self.evictionAge = evictionAge
    }

    /// Round up so near-identical requests collapse onto one allocation.
    ///
    /// 64-pixel granularity below 2K and 128 above: fine enough that the wasted margin stays
    /// small relative to the target, coarse enough that a scene animating a size does not
    /// allocate a fresh bucket every frame.
    static func bucketSize(_ value: Int) -> Int {
        guard value > 0 else { return 64 }
        let granularity = value <= 2048 ? 64 : 128
        return ((value + granularity - 1) / granularity) * granularity
    }

    /// Borrow a target for the duration of `body`. Scoped rather than manual release because a
    /// leaked target is invisible until memory climbs.
    public func withTexture<T>(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        sampleCount: Int = 1,
        _ body: (PooledTexture) throws -> T
    ) rethrows -> T? {
        guard let pooled = acquire(
            width: width, height: height, pixelFormat: pixelFormat, sampleCount: sampleCount
        ) else { return nil }
        defer { release(pooled) }
        return try body(pooled)
    }

    public func acquire(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        sampleCount: Int = 1
    ) -> PooledTexture? {
        let key = BucketKey(
            width: Self.bucketSize(width),
            height: Self.bucketSize(height),
            pixelFormat: pixelFormat,
            sampleCount: sampleCount
        )

        if var bucket = available[key], let reused = bucket.popLast() {
            available[key] = bucket
            reused.framesSinceUse = 0
            inFlight[ObjectIdentifier(reused)] = reused
            reuseCount += 1
            return reused
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: key.width, height: key.height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        // GPU-only. A render target the CPU never reads has no business being in shared memory.
        descriptor.storageMode = .private
        descriptor.sampleCount = sampleCount
        if sampleCount > 1 { descriptor.textureType = .type2DMultisample }

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            log.error("could not allocate \(key.width)x\(key.height) render target")
            return nil
        }
        texture.label = "fbo-\(key.width)x\(key.height)"

        currentBytes += Self.byteSize(of: key)
        peakBytes = max(peakBytes, currentBytes)
        allocationCount += 1

        let pooled = PooledTexture(texture: texture, key: key, pool: self)
        inFlight[ObjectIdentifier(pooled)] = pooled
        return pooled
    }

    public func release(_ pooled: PooledTexture) {
        guard inFlight.removeValue(forKey: ObjectIdentifier(pooled)) != nil else { return }
        pooled.framesSinceUse = 0
        available[pooled.key, default: []].append(pooled)

        // Over budget: drop the idle surplus rather than let a pathological scene pin memory.
        if currentBytes > byteBudget { evictIdle(force: true) }
    }

    /// Call once per frame. Ages idle buckets so they eventually go back to the system.
    public func endFrame() {
        for bucket in available.values {
            for texture in bucket { texture.framesSinceUse += 1 }
        }
        evictIdle(force: false)
    }

    private func evictIdle(force: Bool) {
        for (key, bucket) in available {
            let survivors = bucket.filter { force ? false : $0.framesSinceUse < evictionAge }
            let evicted = bucket.count - survivors.count
            guard evicted > 0 else { continue }
            currentBytes -= evicted * Self.byteSize(of: key)
            if survivors.isEmpty { available.removeValue(forKey: key) }
            else { available[key] = survivors }
        }
    }

    public func drain() {
        available.removeAll()
        currentBytes = 0
    }

    static func byteSize(of key: BucketKey) -> Int {
        let bytesPerPixel: Int = switch key.pixelFormat {
        case .bgra8Unorm, .bgra8Unorm_srgb, .rgba8Unorm, .rgba8Unorm_srgb: 4
        case .rgba16Float: 8
        case .rgba32Float: 16
        case .r8Unorm: 1
        case .rg8Unorm: 2
        default: 4
        }
        return key.width * key.height * bytesPerPixel * max(1, key.sampleCount)
    }
}
