import Metal
import Testing
@testable import MetalRenderer

@Suite("FBOPool")
struct FBOPoolTests {

    @Test("Rounds sizes into shared buckets")
    func bucketing() {
        // 1920x1080 and 1900x1070 must not hold two full-size targets.
        #expect(FBOPool.bucketSize(1900) == FBOPool.bucketSize(1920))
        #expect(FBOPool.bucketSize(1) == 64)
        #expect(FBOPool.bucketSize(64) == 64)
        #expect(FBOPool.bucketSize(65) == 128)
    }

    @Test("Reuses a released target instead of allocating again")
    func reuses() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pool = FBOPool(device: device)

        guard let first = pool.acquire(width: 256, height: 256) else { return }
        let allocationsAfterFirst = pool.allocationCount
        pool.release(first)

        guard let second = pool.acquire(width: 256, height: 256) else { return }
        // Allocating per frame is the easiest way to lose the performance target.
        #expect(pool.allocationCount == allocationsAfterFirst)
        #expect(pool.reuseCount >= 1)
        pool.release(second)
    }

    @Test("Tracks its own memory footprint")
    func tracksBytes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pool = FBOPool(device: device)
        guard let texture = pool.acquire(width: 256, height: 256) else { return }
        #expect(pool.currentBytes >= 256 * 256 * 4)
        #expect(pool.peakBytes >= pool.currentBytes)
        pool.release(texture)
    }
}
