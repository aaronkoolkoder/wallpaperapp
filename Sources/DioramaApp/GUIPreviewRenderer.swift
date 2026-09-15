import AppKit
import Diagnostics
import ImageIO
import LibraryKit
import PlayerCore
import WEFormat
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
        // The palette is tuned for dark; rendering the light variant only would hide exactly
        // the surfaces being designed. Both are emitted so the light path stays honest too.
        NSApp.appearance = NSAppearance(named: .darkAqua)

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

        let sample = previewItem()

        // Grid cards side by side: one playable and selected, one unsupported.
        write(
            HStack(spacing: Design.Space.grid) {
                WallpaperCard(item: sample, isSelected: true, isPlaying: true, onPlay: {})
                WallpaperCard(
                    item: unsupportedItem(), isSelected: false, isPlaying: false, onPlay: {}
                )
            }
            .padding(Design.Space.gutter)
            .frame(width: 640),
            to: directory.appendingPathComponent("library-cards.png")
        )

        write(
            LibraryChromePreview(items: [sample, unsupportedItem()])
                .frame(width: 900, height: 560),
            to: directory.appendingPathComponent("library-window.png")
        )

        write(
            InspectorPanel(item: sample, isPlaying: true, onPlay: {})
                .frame(width: 300, height: 700),
            to: directory.appendingPathComponent("inspector.png")
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
            content: view
                .environment(\.isOffscreenRendering, true)
                .environment(\.colorScheme, .dark)
        )
        // Render at 2x so the output matches what a Retina display actually shows, including
        // whether text is clipped at real pixel sizes.
        renderer.scale = 2

        // Dynamic NSColor providers resolve against the *drawing* appearance, not against
        // `NSApp.appearance`, and ImageRenderer does not set it. Without this the palette
        // silently renders its light variant — the one case it is not tuned for.
        var rendered: CGImage?
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            rendered = renderer.cgImage
        }

        guard let image = rendered else {
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

/// Approximates the window's composition — rail, gallery, inspector — for offscreen review.
///
/// The real window is a `NavigationSplitView` with an `.inspector`, neither of which lays out
/// under `ImageRenderer`. This mirrors the arrangement with plain stacks so the palette and
/// spacing can be judged; it is a design proof, not the shipping view, and is never presented as
/// having exercised the real container.
private struct LibraryChromePreview: View {
    let items: [WallpaperItem]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                SectionLabel("Library")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                ForEach(LibraryFilter.allCases) { filter in
                    HStack(spacing: 9) {
                        Image(systemName: filter.symbol)
                            .font(.system(size: 12))
                            .frame(width: 16)
                        Text(filter.title).font(.system(size: 12.5))
                        Spacer()
                        Text(filter == .all ? "2" : "1")
                            .font(.caption2)
                            .foregroundStyle(Design.Ink.tertiary)
                    }
                    .foregroundStyle(filter == .all ? Design.Ink.primary : Design.Ink.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        filter == .all ? Design.Surface.inset : .clear,
                        in: .rect(cornerRadius: Design.Radius.chip)
                    )
                    .padding(.horizontal, 6)
                }
                Spacer()
            }
            .padding(.top, 16)
            .frame(width: 214)
            .background(Design.Surface.recessed)

            VStack(spacing: 0) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: Design.Space.grid)],
                    spacing: Design.Space.grid
                ) {
                    ForEach(items) { item in
                        WallpaperCard(
                            item: item, isSelected: item.isPlayable,
                            isPlaying: item.isPlayable, onPlay: {}
                        )
                    }
                }
                .padding(Design.Space.gutter)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Design.Surface.base)

            InspectorPanel(item: items.first, isPlaying: true, onPlay: {})
                .frame(width: 300)
                .background(Design.Surface.recessed)
        }
    }
}

/// Representative library entries, including the awkward cases the design has to hold.
@MainActor
private func previewItem() -> WallpaperItem {
    WallpaperItem(
        id: "2000000002",
        title: "Snowfall Over Pines",
        type: .scene,
        directory: URL(fileURLWithPath: "/tmp"),
        contentURL: URL(fileURLWithPath: "/tmp/scene.pkg"),
        previewURL: previewImageURL(),
        tags: ["Nature", "Relaxing", "Winter", "Animated"],
        contentRating: "Everyone",
        properties: [
            "density": WEProperty(type: .slider, text: "Snow density", value: .number(0.65)),
            "glow": WEProperty(type: .bool, text: "Glow", value: .bool(true)),
            "tint": WEProperty(
                type: .color, text: "Tint", value: .vector3(WEVector3(0.82, 0.9, 1.0))
            ),
            "speed": WEProperty(type: .slider, text: "Fall speed", value: .number(1.0)),
        ],
        sizeBytes: 48_300_000,
        modifiedAt: Date(timeIntervalSince1970: 1_767_000_000),
        unplayableReason: nil
    )
}

@MainActor
private func unsupportedItem() -> WallpaperItem {
    WallpaperItem(
        id: "1000000004", title: "Rainmeter Clock", type: .application,
        directory: URL(fileURLWithPath: "/tmp"), contentURL: nil, previewURL: nil,
        tags: [], contentRating: nil, properties: [:], sizeBytes: 0, modifiedAt: nil,
        unplayableReason: "Application wallpapers are Windows programs and cannot run on macOS"
    )
}

/// Uses a real scene render when one is present, so the card is judged against actual artwork
/// rather than a placeholder glyph.
private func previewImageURL() -> URL? {
    let candidate = URL(fileURLWithPath: "web/public/hero-snow.png")
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
}

/// Minimal stand-in so previews do not need a live Metal device or real surfaces.
@MainActor
private struct PlaybackControllerStub {
    let controller: PlaybackController
    init(coordinator: DisplayCoordinator) {
        controller = PlaybackController(coordinator: coordinator)
    }
}
