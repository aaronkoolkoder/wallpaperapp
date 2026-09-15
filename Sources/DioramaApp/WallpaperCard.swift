import AppKit
import LibraryKit
import SwiftUI
import WEFormat

extension WallpaperItem {
    /// Visual treatment for this wallpaper's *format*, independent of whether we can play it.
    ///
    /// Kept separate from playability on purpose: an unsupported item still has a real type, and
    /// collapsing the two made the card say "Unsupported" twice — once as its type and again as
    /// its warning — which reads as a rendering glitch rather than as information.
    var appearance: WallpaperTypeAppearance {
        switch type {
        case .scene: .scene
        case .video: .video
        case .web: .web
        case .application, .unknown: .unsupported
        }
    }

    /// Type name as shown to a person, including for formats we cannot play.
    var typeLabel: String {
        switch type {
        case .scene: "Scene"
        case .video: "Video"
        case .web: "Web"
        case .application: "Application"
        case .unknown(let raw): raw.isEmpty ? "Unknown" : raw.capitalized
        }
    }
}

/// One wallpaper in the grid.
///
/// Reads as a piece of artwork first and metadata second: the preview fills the card, and the
/// title and type sit on a translucent strip over it rather than in a separate row beneath. That
/// keeps a dense grid feeling like a gallery instead of a file listing, which is the difference
/// between browsing a wallpaper library and administering one.
struct WallpaperCard: View {
    let item: WallpaperItem
    let isSelected: Bool
    let isPlaying: Bool
    let onPlay: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            preview
        }
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Design.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.card)
                .strokeBorder(
                    isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator.opacity(0.6)),
                    lineWidth: isSelected ? 2.5 : 0.5
                )
        }
        .clipShape(.rect(cornerRadius: Design.Radius.card))
        // A gentle lift on hover, not a jump. Scaling a grid of 300 cards aggressively makes
        // the whole view feel unstable as the pointer crosses it.
        .scaleEffect(isHovering ? 1.015 : 1.0)
        .shadow(
            color: .black.opacity(isHovering ? 0.22 : 0.10),
            radius: isHovering ? 14 : 5,
            y: isHovering ? 6 : 2
        )
        .animation(.smooth(duration: 0.18), value: isHovering)
        .animation(.smooth(duration: 0.18), value: isSelected)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .help(item.unplayableReason ?? item.title)
        .contextMenu {
            Button("Set as Wallpaper", action: onPlay).disabled(!item.isPlayable)
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.directory])
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var preview: some View {
        ZStack(alignment: .bottom) {
            artwork
            captionStrip
            if isHovering && item.isPlayable { playAffordance }
            if isPlaying { playingBadge }
        }
        .aspectRatio(Design.Grid.aspect, contentMode: .fit)
    }

    private var artwork: some View {
        ZStack {
            Rectangle().fill(.quaternary)

            if let url = item.previewURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.appearance.symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
            }

            if !item.isPlayable {
                // Desaturated, not hidden: the user should still recognise the wallpaper they
                // are being told about.
                Rectangle().fill(.black.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Title and type over a gradient scrim, so text stays readable on any artwork.
    private var captionStrip: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)

            HStack(spacing: 5) {
                Chip(text: item.typeLabel, systemImage: item.appearance.symbol, tint: .white)
                if !item.isPlayable {
                    Chip(text: "Unsupported", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [.clear, .black.opacity(0.55), .black.opacity(0.8)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private var playAffordance: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.28))
            Image(systemName: "play.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.white, .white.opacity(0.28))
                .shadow(radius: 8)
        }
        .transition(.opacity)
    }

    private var playingBadge: some View {
        VStack {
            HStack {
                Spacer()
                Label("Playing", systemImage: "waveform")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tint, in: .capsule)
                    .foregroundStyle(.white)
                    .padding(9)
            }
            Spacer()
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.title, item.appearance.label]
        if isPlaying { parts.append("currently playing") }
        if let reason = item.unplayableReason { parts.append("unsupported: \(reason)") }
        return parts.joined(separator: ", ")
    }
}
