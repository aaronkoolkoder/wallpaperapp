import AppKit
import Diagnostics
import Foundation
import Metal
import MetalRenderer
import QuartzCore
import SceneEngine
import WallpaperKit
import os

/// Renders Wallpaper Engine Scene wallpapers natively in Metal.
///
/// The only backend that needs the surface's display link, since a scene has no timebase of its
/// own — everything else schedules its own frames.
@MainActor
public final class SceneBackend: WallpaperBackend {
    public static let kind: WallpaperKind = .scene
    public static let needsDisplayLink = true

    public private(set) var contentFrameRate: Int?
    public private(set) var report: CompatibilityReport

    private var renderer: SceneRenderer?
    private weak var surface: DesktopSurface?
    private var isPaused = false
    private let log = Logger(subsystem: "app.diorama", category: "scene")

    public init() {
        report = CompatibilityReport(wallpaperID: "")
    }

    public func start(_ request: WallpaperRequest, on surface: DesktopSurface) throws {
        stop()
        report = CompatibilityReport(wallpaperID: request.id)

        let renderDevice = try RenderDevice.system()
        let renderer = try SceneRenderer(renderDevice: renderDevice)

        let scene = try SceneRenderer.loadScene(
            directory: request.baseURL,
            packageURL: request.contentURL,
            wallpaperID: request.id,
            device: renderDevice.device
        )
        renderer.setScene(scene)

        // Carry the build-time findings forward: which objects we skipped and why is exactly
        // what the user needs to see in the compatibility panel.
        for finding in scene.report.findings { report.add(finding) }

        if scene.layers.isEmpty {
            report.add(
                .unsupported, feature: "Scene",
                detail: "no drawable layers were found in this wallpaper"
            )
        }

        guard let metalLayer = surface.mountMetalLayer() else {
            throw BackendError.contentUnreadable(
                request.contentURL, underlying: "could not attach a Metal layer to the display"
            )
        }

        self.renderer = renderer
        self.surface = surface

        surface.onFrame = { [weak self] _ in
            guard let self, !self.isPaused else { return }
            self.renderer?.render(to: metalLayer)
        }

        log.info("scene started: \(scene.layers.count) layer(s) for \(request.id, privacy: .public)")
    }

    public func stop() {
        surface?.onFrame = nil
        renderer = nil
        surface = nil
        isPaused = false
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    public var layerCount: Int { renderer?.scene?.layers.count ?? 0 }
    public var framesRendered: UInt64 { renderer?.framesRendered ?? 0 }
}
