import Foundation
import Testing
@testable import SceneEngine

@Suite("AudioSpectrum")
struct AudioSpectrumTests {

    /// A pure tone at `frequency`, sampled at 44.1kHz.
    private func tone(frequency: Double, count: Int = 1024, amplitude: Float = 0.8) -> [Float] {
        (0 ..< count).map { index in
            amplitude * Float(sin(2 * .pi * frequency * Double(index) / 44_100))
        }
    }

    private func silence(count: Int = 1024) -> [Float] {
        [Float](repeating: 0, count: count)
    }

    @Test("Silence produces no energy")
    func silenceIsSilent() {
        let analyzer = AudioSpectrumAnalyzer()
        let bands = analyzer.bands(from: silence())
        #expect(bands.count == AudioFrame.bandCount)
        #expect(bands.allSatisfy { $0 < 0.001 })
    }

    @Test("A tone puts energy somewhere, and not everywhere")
    func toneIsLocalised() {
        let analyzer = AudioSpectrumAnalyzer()
        let bands = analyzer.bands(from: tone(frequency: 1000))

        let loudest = bands.enumerated().max { $0.element < $1.element }
        #expect(loudest != nil)
        #expect((loudest?.element ?? 0) > 0.01)
        // Energy must not be smeared across the whole spectrum — that is what a missing window
        // function looks like, and it makes every wallpaper react to everything equally.
        let quiet = bands.filter { $0 < (loudest?.element ?? 1) * 0.25 }.count
        #expect(quiet > AudioFrame.bandCount / 2)
    }

    @Test("A higher tone lands in a higher band than a lower one")
    func frequencyOrdering() {
        let analyzer = AudioSpectrumAnalyzer()
        func peakBand(_ frequency: Double) -> Int {
            let bands = analyzer.bands(from: tone(frequency: frequency))
            return bands.enumerated().max { $0.element < $1.element }?.offset ?? 0
        }
        // Not a specific band — the exact mapping depends on the grouping curve — but the
        // ordering has to hold or the spectrum is meaningless.
        #expect(peakBand(200) < peakBand(2000))
        #expect(peakBand(2000) < peakBand(10_000))
    }

    @Test("Bands are logarithmic, so bass does not swamp everything")
    func logarithmicGrouping() {
        let analyzer = AudioSpectrumAnalyzer()
        // With linear grouping a 200Hz tone would land in band 0 of 64; pitch is logarithmic so
        // the bands have to be, and low frequencies should occupy several bands rather than one.
        let bands = analyzer.bands(from: tone(frequency: 200))
        let peak = bands.enumerated().max { $0.element < $1.element }?.offset ?? 0
        #expect(peak > 0)
    }

    @Test("Output is bounded regardless of input level")
    func outputIsBounded() {
        let analyzer = AudioSpectrumAnalyzer()
        // Content can be mastered arbitrarily loud; a band above 1 would push a shader uniform
        // out of the range a wallpaper expects.
        let bands = analyzer.bands(from: tone(frequency: 440, amplitude: 50))
        #expect(bands.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("An empty buffer yields silence rather than crashing")
    func emptyBuffer() {
        let analyzer = AudioSpectrumAnalyzer()
        let bands = analyzer.bands(from: [])
        #expect(bands.count == AudioFrame.bandCount)
        #expect(bands.allSatisfy { $0 == 0 })
    }

    @Test("A short buffer is padded rather than rejected")
    func shortBuffer() {
        let analyzer = AudioSpectrumAnalyzer()
        // Capture callbacks do not deliver a tidy power-of-two every time.
        let bands = analyzer.bands(from: tone(frequency: 1000, count: 300))
        #expect(bands.count == AudioFrame.bandCount)
        #expect(bands.contains { $0 > 0 })
    }

    // MARK: - Smoothing

    @Test("Attack is faster than release")
    func attackFasterThanRelease() {
        let analyzer = AudioSpectrumAnalyzer()
        let loud = tone(frequency: 1000)

        var rising = AudioFrame.silent
        for _ in 0 ..< 3 { rising = analyzer.analyze(left: loud, right: loud) }
        let peak = rising.left.max() ?? 0

        var falling = AudioFrame.silent
        for _ in 0 ..< 3 { falling = analyzer.analyze(left: silence(), right: silence()) }
        let decayed = falling.left.max() ?? 0

        // A beat should snap in and fall away. Equal rates make it mush; release faster than
        // attack makes it flicker.
        #expect(peak > 0)
        #expect(decayed > 0)
        #expect(decayed < peak)
    }

    @Test("Smoothing converges rather than oscillating")
    func smoothingConverges() {
        let analyzer = AudioSpectrumAnalyzer()
        let loud = tone(frequency: 1000)
        var previous: Float = 0
        for _ in 0 ..< 40 {
            let frame = analyzer.analyze(left: loud, right: loud)
            let current = frame.left.max() ?? 0
            #expect(current >= previous - 0.001)
            previous = current
        }
    }

    @Test("Reset clears the smoothing state")
    func resetClears() {
        let analyzer = AudioSpectrumAnalyzer()
        let loud = tone(frequency: 1000)
        for _ in 0 ..< 5 { _ = analyzer.analyze(left: loud, right: loud) }
        analyzer.reset()
        let frame = analyzer.analyze(left: silence(), right: silence())
        #expect((frame.left.max() ?? 1) < 0.001)
    }

    @Test("Amplitude tracks level and stays bounded")
    func amplitudeBounded() {
        let analyzer = AudioSpectrumAnalyzer()
        let quiet = analyzer.analyze(left: tone(frequency: 440, amplitude: 0.05), right: silence())
        analyzer.reset()
        let loud = analyzer.analyze(left: tone(frequency: 440, amplitude: 0.9), right: silence())

        #expect(loud.amplitude > quiet.amplitude)
        #expect(loud.amplitude <= 1)
        #expect(quiet.amplitude >= 0)
    }

    @Test("Channels are analysed independently")
    func channelsIndependent() {
        let analyzer = AudioSpectrumAnalyzer()
        var frame = AudioFrame.silent
        for _ in 0 ..< 5 {
            frame = analyzer.analyze(left: tone(frequency: 1000), right: silence())
        }
        #expect((frame.left.max() ?? 0) > 0.001)
        #expect((frame.right.max() ?? 1) < 0.001)
    }

    @Test("A silent frame reports the expected shape")
    func silentFrameShape() {
        #expect(AudioFrame.silent.left.count == AudioFrame.bandCount)
        #expect(AudioFrame.silent.right.count == AudioFrame.bandCount)
        #expect(AudioFrame.silent.amplitude == 0)
    }
}
