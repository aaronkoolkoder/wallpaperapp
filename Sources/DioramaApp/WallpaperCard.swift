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
        .background(Design.Surface.raised, in: .rect(cornerRadius: Design.Radius.card))
        .clipShape(.rect(cornerRadius: Design.Radius.card))
        .overlay {
            // Selection is a thin bright ring, not a thick accent bar. At this size a heavy
            // border competes with the artwork it is meant to be framing.
            RoundedRectangle(cornerRadius: Design.Radius.card)
                .strokeBorder(
                    isSelected ? Design.Ink.primary.opacity(0.5) : Design.Stroke.subtle,
                    lineWidth: isSelected ? 1 : 0.5
                )
        }
        // A gentle lift, not a jump. Scaling a grid of 300 cards hard makes the whole view feel
        // unstable as the pointer crosses it.
        .scaleEffect(isHovering ? 1.012 : 1.0)
        .shadow(
            color: .black.opacity(isHovering ? 0.34 : 0.16),
            radius: isHovering ? 18 : 7,
            y: isHovering ? 8 : 3
        )
        .animation(Design.Motion.hover, value: isHovering)
        .animation(Design.Motion.selection, value: isSelected)
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
            Rectangle().fill(Design.Surface.inset)

            if let url = item.previewURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.appearance.symbol)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Design.Ink.secondary.opacity(0.5))
            }

            if !item.isPlayable {
                // Dimmed, not crushed. A multiply blend here took the card to near-black and
                // made the artwork unrecognisable, which defeats the point — someone told an
                // item is unsupported still needs to see which item it is.
                Rectangle().fill(Design.Surface.base.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Title and type over a gradient scrim, so text stays readable on any artwork.
    private var captionStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.7), radius: 3, y: 1)

            HStack(spacing: 5) {
                // On artwork the type reads as a symbol plus a word in plain white — a tinted
                // chip here would fight whatever is behind it.
                HStack(spacing: 4) {
                    Image(systemName: item.appearance.symbol)
                        .font(.system(size: 9, weight: .semibold))
                    Text(item.typeLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .tracking(0.2)
                }
                .foregroundStyle(.white.opacity(0.82))
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)

                if !item.isPlayable {
                    Chip(
                        text: "Unsupported", systemImage: "exclamationmark.triangle",
                        tint: Design.Status.warning, isProminent: true
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // A taller, softer scrim than a hard band: it has to carry white text over
            // arbitrary artwork without looking like a pasted-on bar.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.35), location: 0.45),
                    .init(color: .black.opacity(0.78), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private var playAffordance: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.32))
            Image(systemName: "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Design.Ink.primary)
                .frame(width: 46, height: 46)
                .background(.white.opacity(0.92), in: .circle)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        }
        .transition(.opacity)
    }

    private var playingBadge: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "waveform").font(.system(size: 9, weight: .bold))
                    Text("PLAYING")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                }
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(Design.Status.playing, in: .capsule)
                .padding(11)
            }
            Spacer()
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.title, item.typeLabel]
        if isPlaying { parts.append("currently playing") }
        if let reason = item.unplayableReason { parts.append("unsupported: \(reason)") }
        return parts.joined(separator: ", ")
    }
}
