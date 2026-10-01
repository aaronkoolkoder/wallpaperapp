import AppKit
import Diagnostics
import LibraryKit
import SwiftUI
import WallpaperKit

/// The menu bar popover: what is playing, on which display, and how much it is costing.
///
/// Built as a SwiftUI popover rather than an `NSMenu` because the useful content here is a
/// preview and a live state readout, neither of which a menu can show. Adopts Liquid Glass so it
/// reads as part of macOS 26 rather than as a panel bolted on top of it.
struct MenuBarView: View {
    @Bindable var model: WallpaperSystemModel
    @Environment(\.isOffscreenRendering) private var isOffscreenRendering
    let onOpenLibrary: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            if model.displays.isEmpty {
                emptyState
            } else {
                displayList
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 340)
        .task { model.refresh() }
    }

    /// `ScrollView` lays out no content under `ImageRenderer` — it renders as empty space, with
    /// no warning. Since the offscreen harness exists precisely to catch broken layout, a
    /// container that silently renders nothing there would defeat it. Verified by rendering the
    /// same cards inside and outside a ScrollView: outside they appear, inside they do not.
    @ViewBuilder
    private var displayList: some View {
        if isOffscreenRendering {
            VStack(spacing: 10) {
                ForEach(model.displays) { display in
                    DisplayCard(display: display, onClear: { model.clear(display.id) })
                }
            }
            .padding(12)
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.displays) { display in
                        DisplayCard(display: display, onClear: { model.clear(display.id) })
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 300)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Diorama")
                    .font(.headline)
                Spacer()
                Text(model.energySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let warning = model.thermalWarning {
                Label(warning, systemImage: "thermometer.high")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                model.togglePause()
            } label: {
                Label(
                    model.isPaused ? "Resume Wallpapers" : "Pause Wallpapers",
                    systemImage: model.isPaused ? "play.fill" : "pause.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(model.isPaused ? .green : .accentColor)
            .keyboardShortcut("p")
        }
        .padding(14)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No displays detected")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                onOpenLibrary()
            } label: {
                Label("Library", systemImage: "square.grid.2x2")
            }
            .keyboardShortcut("l")

            Button {
                onOpenSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",")

            Spacer()

            Button {
                onQuit()
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Diorama")
            .keyboardShortcut("q")
        }
        .buttonStyle(.accessoryBar)
        .padding(10)
    }
}

/// One display's current state.
private struct DisplayCard: View {
    let display: DisplaySnapshot
    let onClear: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 11) {
            thumbnail

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(display.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if display.isMain {
                        Text("Main")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                }

                Text(display.wallpaperTitle ?? "No wallpaper")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Circle()
                        .fill(display.isRunning ? .green : .secondary)
                        .frame(width: 6, height: 6)
                    Text(display.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Surfaces the "legible failure" promise right where the wallpaper is named,
                // rather than hiding it in a separate inspector the user has to go looking for.
                if let report = display.report, !report.isFullySupported {
                    Label(report.summary, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Shown whenever something is playing rather than on hover: a control that only
            // exists once the pointer is already on it is one nobody finds when they are
            // looking for how to take a wallpaper off.
            if display.wallpaperTitle != nil {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(isHovering ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this wallpaper")
                .accessibilityLabel("Remove the wallpaper on \(display.name)")
            }
        }
        .padding(10)
        .adaptiveGlass(cornerRadius: 12)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(display.name), \(display.wallpaperTitle ?? "no wallpaper"), \(display.statusText)"
        )
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(.quaternary)

            // Small, so a small decode: the menu bar thumbnail is about 60 points across and
            // decoding a megabyte-and-a-half GIF for it would stall the popover opening.
            PreviewImage(url: display.previewURL, fallbackSymbol: "photo", maxPixel: 200)

            if !display.isRunning && display.wallpaperTitle != nil {
                // Dim rather than hide: the user should still recognise what is loaded, even
                // while it is suspended.
                RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.45))
                Image(systemName: "pause.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: 58, height: 36)
        .clipShape(.rect(cornerRadius: 7))
    }
}
