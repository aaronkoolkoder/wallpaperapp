import Accelerate
import Foundation
import os

/// A frame of analysed audio, in the shape Wallpaper Engine wallpapers expect.
///
/// Wallpaper Engine exposes audio as 64 bands per channel, normalised to roughly 0...1. Matching
/// that shape here means a scene's own audio-reactive properties map across without translation.
public struct AudioFrame: Sendable {
    public static let bandCount = 64

    public var left: [Float]
    public var right: [Float]
    /// Broadband level, useful for scenes that just want "is something playing".
    public var amplitude: Float

    public init(
        left: [Float] = .init(repeating: 0, count: AudioFrame.bandCount),
        right: [Float] = .init(repeating: 0, count: AudioFrame.bandCount),
        amplitude: Float = 0
    ) {
        self.left = left
        self.right = right
        self.amplitude = amplitude
    }

    public static let silent = AudioFrame()
}

/// Turns PCM into bands.
///
/// Deliberately separate from capture: the FFT and the smoothing are the part worth testing, and
/// testing them should not require a microphone, a permission prompt, or anything playing.
public final class AudioSpectrumAnalyzer: @unchecked Sendable {
    private let log2n: vDSP_Length
    private let frameCount: Int
    private let fft: FFTSetup?
    private var window: [Float]

    /// Per-band smoothing. Raw FFT output flickers hard frame to frame, and a wallpaper driven
    /// directly by it looks like a strobing equaliser rather than something responding to music.
    private var smoothedLeft: [Float]
    private var smoothedRight: [Float]

    /// Attack is fast and release is slow, which is how every level meter worth using behaves:
    /// a beat should snap in and fall away, not fade in.
    public var attack: Float = 0.55
    public var release: Float = 0.12

    public init(frameCount: Int = 1024) {
        // Power of two, since vDSP's real FFT requires it.
        let rounded = max(64, 1 << Int(log2(Double(frameCount)).rounded()))
        self.frameCount = rounded
        log2n = vDSP_Length(log2(Double(rounded)))
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        window = [Float](repeating: 0, count: rounded)
        // Hann window: without one, a signal that does not fit a whole number of cycles in the
        // buffer smears energy across every band and the spectrum looks like noise.
        vDSP_hann_window(&window, vDSP_Length(rounded), Int32(vDSP_HANN_NORM))

        smoothedLeft = [Float](repeating: 0, count: AudioFrame.bandCount)
        smoothedRight = [Float](repeating: 0, count: AudioFrame.bandCount)
    }

    deinit {
        if let fft { vDSP_destroy_fftsetup(fft) }
    }

    /// Analyse one interleaved or planar stereo buffer.
    public func analyze(left: [Float], right: [Float]) -> AudioFrame {
        let leftBands = bands(from: left)
        let rightBands = bands(from: right)

        smoothedLeft = smooth(leftBands, into: smoothedLeft)
        smoothedRight = smooth(rightBands, into: smoothedRight)

        var amplitude: Float = 0
        vDSP_rmsqv(left, 1, &amplitude, vDSP_Length(left.count))
        // A little headroom, then clamp: RMS of normal programme material sits well below 1.
        amplitude = min(1, amplitude * 3)

        return AudioFrame(left: smoothedLeft, right: smoothedRight, amplitude: amplitude)
    }

    private func smooth(_ incoming: [Float], into previous: [Float]) -> [Float] {
        var result = previous
        for index in result.indices where index < incoming.count {
            let target = incoming[index]
            let rate = target > result[index] ? attack : release
            result[index] += (target - result[index]) * rate
        }
        return result
    }

    /// FFT one channel down to bands.
    func bands(from samples: [Float]) -> [Float] {
        guard let fft, !samples.isEmpty else {
            return [Float](repeating: 0, count: AudioFrame.bandCount)
        }

        var padded = [Float](repeating: 0, count: frameCount)
        let copyCount = min(samples.count, frameCount)
        padded.replaceSubrange(0 ..< copyCount, with: samples[0 ..< copyCount])
        vDSP_vmul(padded, 1, window, 1, &padded, 1, vDSP_Length(frameCount))

        let half = frameCount / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!
                )
                padded.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        return group(magnitudes)
    }

    /// Collapse FFT bins into bands on a logarithmic scale.
    ///
    /// Linear bands would put almost everything musical into the first few and leave the rest
    /// showing inaudible high frequencies — pitch is logarithmic, so the bands have to be too.
    func group(_ magnitudes: [Float]) -> [Float] {
        var bands = [Float](repeating: 0, count: AudioFrame.bandCount)
        guard !magnitudes.isEmpty else { return bands }

        let binCount = magnitudes.count
        for band in 0 ..< AudioFrame.bandCount {
            let lowFraction = pow(Double(band) / Double(AudioFrame.bandCount), 2.0)
            let highFraction = pow(Double(band + 1) / Double(AudioFrame.bandCount), 2.0)

            var low = Int(lowFraction * Double(binCount))
            var high = Int(highFraction * Double(binCount))
            low = max(0, min(low, binCount - 1))
            high = max(low + 1, min(high, binCount))

            var sum: Float = 0
            for bin in low ..< high { sum += magnitudes[bin] }
            let mean = sum / Float(high - low)

            // Compress: raw magnitudes are wildly peaky and a linear mapping leaves everything
            // but the bass sitting at zero.
            bands[band] = min(1, sqrt(mean) * 0.22)
        }
        return bands
    }

    public func reset() {
        smoothedLeft = [Float](repeating: 0, count: AudioFrame.bandCount)
        smoothedRight = [Float](repeating: 0, count: AudioFrame.bandCount)
    }
}
