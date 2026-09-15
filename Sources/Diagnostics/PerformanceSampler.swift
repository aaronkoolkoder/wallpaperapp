import Foundation
import os

/// A fixed-capacity rolling window of frame timings.
///
/// Fixed capacity and no allocation after construction: this is sampled every frame on the render
/// path, and a diagnostics tool that allocates per frame would distort the very measurement it
/// exists to take.
public struct FrameStatistics: Sendable {
    public private(set) var mean: Double = 0
    public private(set) var p95: Double = 0
    public private(set) var max: Double = 0
    public private(set) var sampleCount: Int = 0

    public init() {}

    public init(mean: Double, p95: Double, max: Double, sampleCount: Int) {
        self.mean = mean
        self.p95 = p95
        self.max = max
        self.sampleCount = sampleCount
    }
}

/// Samples per-frame CPU and GPU time and reduces them to a rolling summary.
///
/// Thread-safe by lock rather than by actor isolation: `record` is called from Metal completion
/// handlers on a driver thread and must not schedule work or hop actors on the GPU's critical path.
public final class PerformanceSampler: @unchecked Sendable {
    private struct Window {
        var samples: [Double]
        var index: Int = 0
        var filled: Bool = false

        init(capacity: Int) { samples = [Double](repeating: 0, count: capacity) }

        mutating func append(_ value: Double) {
            samples[index] = value
            index = (index + 1) % samples.count
            if index == 0 { filled = true }
        }

        var live: ArraySlice<Double> {
            filled ? samples[...] : samples[..<index]
        }
    }

    private let lock: OSAllocatedUnfairLock<State>

    private struct State {
        var cpu: Window
        var gpu: Window
    }

    public init(capacity: Int = 120) {
        lock = OSAllocatedUnfairLock(
            initialState: State(cpu: Window(capacity: capacity), gpu: Window(capacity: capacity))
        )
    }

    /// - Parameters:
    ///   - cpuMilliseconds: wall time spent encoding the frame on the CPU.
    ///   - gpuMilliseconds: from `MTLCommandBuffer.gpuEndTime - gpuStartTime`.
    public func record(cpuMilliseconds: Double, gpuMilliseconds: Double) {
        lock.withLock { state in
            state.cpu.append(cpuMilliseconds)
            state.gpu.append(gpuMilliseconds)
        }
    }

    public var cpu: FrameStatistics { lock.withLock { Self.summarize($0.cpu.live) } }
    public var gpu: FrameStatistics { lock.withLock { Self.summarize($0.gpu.live) } }

    public func reset() {
        lock.withLock { state in
            state.cpu.index = 0
            state.cpu.filled = false
            state.gpu.index = 0
            state.gpu.filled = false
        }
    }

    private static func summarize(_ samples: ArraySlice<Double>) -> FrameStatistics {
        guard !samples.isEmpty else { return FrameStatistics() }
        let sorted = samples.sorted()
        let sum = sorted.reduce(0, +)
        // Nearest-rank p95. With a 120-sample window the interpolation refinements are noise.
        let rank = Int((Double(sorted.count) * 0.95).rounded(.up)) - 1
        return FrameStatistics(
            mean: sum / Double(sorted.count),
            p95: sorted[Swift.max(0, Swift.min(rank, sorted.count - 1))],
            max: sorted[sorted.count - 1],
            sampleCount: sorted.count
        )
    }
}
