import AppKit
import Diagnostics
import ImageIO
import LibraryKit
import PlayerCore
import SwiftUI
import UniformTypeIdentifiers
import WallpaperKit

/// Renders the app's SwiftUI surfaces to PNG offscreen.
///
/// Exists because the interface is otherwise only verifiable by looking at a running Mac, which
/// needs Screen Recording and a human. `ImageRenderer` lays out and draws the real views with
/// real data, so a layout that breaks shows up here rather than in front of a user.
///
/// **What it cannot cover.** `ImageRenderer` does not lay out several AppKit-backed container
/// views: `ScrollView` and `Form` render as empty space, and `TabView` renders SwiftUI's
/// "cannot render" placeholder. `.glassEffect()` renders nothing at all — it swallows its
/// content rather than degrading. All four were found by probing, not by documentation.
///
/// So this covers the menu bar popover, which is plain composition, and the About panel. The
/// `Form`-based settings panels cannot be verified this way and still need a human to look at
/// them. Pretending otherwise would be worse than the gap: a harness that reports success on a
/// blank image is the same false confidence that let the effects pipeline diverge earlier.
@MainActor
enum GUIPreviewRenderer {
    static func renderAll(to directory: URL) {
        let model = makePreviewModel()

        write(
            // A concrete height as well as width: ImageRenderer gives a ScrollView no
            // resolved size otherwise, and its content renders as empty space.
            MenuBarView(
                model: model, onOpenLibrary: {}, onOpenSettings: {}, onQuit: {}
            )
            .frame(width: 340),
            to: directory.appendingPathComponent("menubar.png")
        )

        // Only the About panel is plain composition; the Form-based panels render blank here
        // and are deliberately not emitted rather than shipped as empty PNGs that look like
        // passing output.
        write(
            AboutView().frame(width: 520, height: 430),
            to: directory.appendingPathComponent("settings-about.png")
        )
    }

    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(
            content: view.environment(\.isOffscreenRendering, true)
        )
        // Render at 2x so the output matches what a Retina display actually shows, including
        // whether text is clipped at real pixel sizes.
        renderer.scale = 2

        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("could not render \(url.lastPathComponent)\n".utf8))
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("rendered \(url.lastPathComponent)")
    }

    /// A model populated with representative state: two displays, one playing with a
    /// compatibility warning and one idle, so the preview exercises the interesting cases
    /// rather than an empty happy path.
    private static func makePreviewModel() -> WallpaperSystemModel {
        let coordinator = DisplayCoordinator()
        let playback = PlaybackControllerStub(coordinator: coordinator)
        let model = WallpaperSystemModel(
            coordinator: coordinator, playback: playback.controller, library: LibraryStore()
        )

        var report = CompatibilityReport(wallpaperID: "2000000002")
        report.add(.degraded, feature: "Particle operator", detail: "mysteryoperator is not supported")

        var state = SystemState()
        state.isOnACPower = false
        state.batteryPercent = 72
        model.injectPreviewState(state)

        model.injectPreviewDisplays([
            DisplaySnapshot(
                id: 1, name: "Built-in Retina Display", isMain: true,
                resolution: CGSize(width: 3024, height: 1964),
                wallpaperTitle: "Snowfall (particles)", wallpaperID: "2000000002",
                previewURL: nil, directive: .running(fps: 30), report: report
            ),
            DisplaySnapshot(
                id: 2, name: "Studio Display", isMain: false,
                resolution: CGSize(width: 5120, height: 2880),
                wallpaperTitle: nil, wallpaperID: nil, previewURL: nil,
                directive: .suspended(reason: .occluded), report: nil
            ),
        ])
        return model
    }
}

/// Minimal stand-in so previews do not need a live Metal device or real surfaces.
@MainActor
private struct PlaybackControllerStub {
    let controller: PlaybackController
    init(coordinator: DisplayCoordinator) {
        controller = PlaybackController(coordinator: coordinator)
    }
}
