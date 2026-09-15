import AVFoundation
import AppKit
import Diagnostics
import Foundation
import WallpaperKit
import os

/// Plays video wallpapers.
///
/// Uses `AVQueuePlayer` + `AVPlayerLooper` rather than hand-feeding an
/// `AVSampleBufferDisplayLayer` from an `AVAssetReader`. The looper exists precisely for
/// gapless repeat and gets it right including at the wrap point, whereas the sample-buffer path
/// means owning the read loop, the timebase, and the wrap ourselves — a lot of surface area for
/// a saving that has to be demonstrated rather than assumed. Decode is hardware in both cases.
/// If measurement later shows the playback graph costing real CPU, the sample-buffer path is the
/// escape hatch.
@MainActor
public final class VideoBackend: WallpaperBackend {
    public static let kind: WallpaperKind = .video

    public private(set) var contentFrameRate: Int?
    public private(set) var report: CompatibilityReport

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var hostView: NSView?
    private let log = Logger(subsystem: "app.diorama", category: "video")

    public init() {
        report = CompatibilityReport(wallpaperID: "")
    }

    public func start(_ request: WallpaperRequest, on surface: DesktopSurface) throws {
        stop()
        report = CompatibilityReport(wallpaperID: request.id)

        guard FileManager.default.fileExists(atPath: request.contentURL.path) else {
            throw BackendError.contentMissing(request.contentURL)
        }

        let asset = AVURLAsset(
            url: request.contentURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let item = AVPlayerItem(asset: asset)

        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = request.isMuted
        // A wallpaper must never hold the display awake. Left at its default this single
        // property turns a decorative background into a battery and screen-burn problem, and
        // it is the most consequential line in this file.
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        // Buffer-and-wait behaviour is for streaming. These are local files.
        queuePlayer.automaticallyWaitsToMinimizeStalling = false

        if request.loops {
            looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        } else {
            queuePlayer.insert(item, after: nil)
        }

        let layer = AVPlayerLayer(player: queuePlayer)
        layer.videoGravity = .resizeAspectFill
        layer.needsDisplayOnBoundsChange = true

        let host = NSView(frame: .zero)
        host.wantsLayer = true
        host.layer = layer
        host.layerContentsRedrawPolicy = .never

        player = queuePlayer
        playerLayer = layer
        hostView = host

        surface.mount(host)
        queuePlayer.play()

        loadTrackMetadata(from: asset, id: request.id)
        log.info("playing \(request.contentURL.lastPathComponent, privacy: .public)")
    }

    public func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        playerLayer?.player = nil
        playerLayer = nil
        player = nil
        hostView = nil
        contentFrameRate = nil
    }

    public func setPaused(_ paused: Bool) {
        // Pausing rather than tearing down: the policy flips this on every occlusion change,
        // and rebuilding the decode pipeline each time a window moves would cost far more than
        // the idle player it avoids.
        if paused { player?.pause() } else { player?.play() }
    }

    /// Reads the nominal frame rate so the power policy never renders faster than the video
    /// actually changes. A 24fps video on a 120Hz display should tick 24 times a second.
    private func loadTrackMetadata(from asset: AVURLAsset, id: String) {
        Task { [weak self] in
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    await MainActor.run {
                        self?.report.add(
                            .unsupported, feature: "Video track",
                            detail: "the file contains no playable video track"
                        )
                    }
                    return
                }
                let rate = try await track.load(.nominalFrameRate)
                await MainActor.run {
                    guard let self else { return }
                    if rate > 0 { self.contentFrameRate = Int(rate.rounded()) }
                }
            } catch {
                await MainActor.run {
                    self?.report.add(
                        .degraded, feature: "Frame rate detection",
                        detail: error.localizedDescription
                    )
                }
            }
        }
    }
}
