import AVFoundation
import Foundation
import ScreenCaptureKit
import os

/// Captures system audio and publishes analysed frames.
///
/// Uses ScreenCaptureKit's audio capture rather than an audio loopback driver. A kernel or
/// HAL driver install is a non-starter for the App Store and a support burden everywhere else
/// (PLAN.md §7.3) — this needs only the Screen Recording permission, and only when the user
/// actually turns the feature on.
///
/// **Nothing here runs unless asked.** The permission prompt is the entire cost of the feature
/// to someone who does not want it, so capture is never started speculatively, and a refusal is
/// reported rather than retried.
@MainActor
public final class SystemAudioCapture: NSObject {
    public enum Status: Equatable, Sendable {
        case idle
        case running
        /// Screen Recording was refused. Recoverable only in System Settings.
        case permissionDenied
        case failed(String)

        public var isRunning: Bool { self == .running }

        public var message: String? {
            switch self {
            case .idle, .running: nil
            case .permissionDenied:
                "Diorama needs Screen Recording permission to read system audio. "
                    + "Grant it in System Settings › Privacy & Security › Screen Recording."
            case .failed(let detail): detail
            }
        }
    }

    public private(set) var status: Status = .idle
    /// Latest analysed frame. Read by the renderer each frame.
    public private(set) var frame: AudioFrame = .silent
    public var onStatusChange: ((Status) -> Void)?

    private var stream: SCStream?
    private let analyzer = AudioSpectrumAnalyzer()
    private let sampleQueue = DispatchQueue(label: "app.diorama.audio", qos: .userInitiated)
    private let log = Logger(subsystem: "app.diorama", category: "audio")

    /// Written on the capture queue, read on the main actor. A lock rather than an actor hop
    /// because this fires at audio rate and must not schedule work.
    private let latest = OSAllocatedUnfairLock(initialState: AudioFrame.silent)

    public override init() { super.init() }

    public func start() async {
        guard status != .running else { return }

        do {
            // Asking for shareable content is what triggers the permission check; there is no
            // way to query it without doing so, which is why this only runs on an explicit
            // opt-in.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                set(.failed("No display available to capture audio from"))
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 44_100
            configuration.channelCount = 2
            // Video is not wanted at all, but SCStream requires a size; the smallest legal one
            // keeps the capture cost to essentially nothing.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()

            self.stream = stream
            set(.running)
            log.info("system audio capture started")
        } catch {
            // TCC refusal surfaces as a generic error, so this is matched on the domain rather
            // than on a specific code, and anything unrecognised is reported verbatim.
            let nsError = error as NSError
            if nsError.domain == SCStreamErrorDomain {
                set(.permissionDenied)
            } else {
                set(.failed(error.localizedDescription))
            }
            log.error("audio capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func stop() {
        guard let stream else { return }
        self.stream = nil
        analyzer.reset()
        frame = .silent
        latest.withLock { $0 = .silent }
        set(.idle)
        Task { try? await stream.stopCapture() }
    }

    /// Pull the most recent frame. Called once per rendered frame.
    public func currentFrame() -> AudioFrame {
        let value = latest.withLock { $0 }
        frame = value
        return value
    }

    private func set(_ newStatus: Status) {
        guard status != newStatus else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }
}

extension SystemAudioCapture: SCStreamDelegate {
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.stream = nil
            self.set(.failed(error.localizedDescription))
        }
    }
}

extension SystemAudioCapture: SCStreamOutput {
    nonisolated public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let samples = Self.planarFloats(from: sampleBuffer) else { return }

        let analysed = analyzer.analyze(left: samples.left, right: samples.right)
        latest.withLock { $0 = analysed }
    }

    /// Extract planar float channels from a capture buffer.
    ///
    /// ScreenCaptureKit delivers non-interleaved 32-bit float, but a buffer can carry one
    /// channel or several; mono is duplicated rather than left silent on one side.
    nonisolated static func planarFloats(
        from sampleBuffer: CMSampleBuffer
    ) -> (left: [Float], right: [Float])? {
        guard let description = sampleBuffer.formatDescription,
              let basic = description.audioStreamBasicDescription,
              basic.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else { return nil }

        var blockBuffer: CMBlockBuffer?
        let listSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * 7
        let listMemory = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { listMemory.deallocate() }
        let list = listMemory.assumingMemoryBound(to: AudioBufferList.self)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first,
              let firstData = first.mData
        else { return nil }

        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return nil }

        let left = Array(
            UnsafeBufferPointer(
                start: firstData.assumingMemoryBound(to: Float.self), count: count
            )
        )

        if buffers.count > 1, let secondData = buffers[1].mData {
            let rightCount = Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size
            let right = Array(
                UnsafeBufferPointer(
                    start: secondData.assumingMemoryBound(to: Float.self), count: rightCount
                )
            )
            return (left, right)
        }
        // Mono: both sides get the same signal rather than one going dead.
        return (left, left)
    }
}
