import AppKit
import LibraryKit
import SwiftUI
import WEFormat

struct WallpaperGrid: View {
    let items: [WallpaperItem]
    @Binding var selection: WallpaperItem.ID?
    let onPlay: (WallpaperItem) -> Void

    /// Adaptive rather than a fixed column count, so the grid reflows instead of leaving a dead
    /// gutter when the window is resized.
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { item in
                    WallpaperCard(
                        item: item,
                        isSelected: selection == item.id,
                        onPlay: { onPlay(item) }
                    )
                    .onTapGesture { selection = item.id }
                    .onTapGesture(count: 2) { onPlay(item) }
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }
}

struct WallpaperCard: View {
    let item: WallpaperItem
    let isSelected: Bool
    let onPlay: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: typeSymbol)
                        .font(.caption2)
                    Text(item.type.rawValue.capitalized)
                        .font(.caption)
                    if !item.isPlayable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: isSelected ? 0 : 0.5)
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .help(item.unplayableReason ?? item.title)
        .contextMenu {
            Button("Set as Wallpaper", action: onPlay)
                .disabled(!item.isPlayable)
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
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)

            if let url = item.previewURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: typeSymbol)
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
            }

            if !item.isPlayable {
                // Desaturate rather than hide: the user should still recognise the wallpaper
                // they are being told about.
                Rectangle().fill(.black.opacity(0.45))
            }

            if isHovering && item.isPlayable {
                Rectangle().fill(.black.opacity(0.3))
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 8))
    }

    private var typeSymbol: String {
        switch item.type {
        case .scene: "cube.transparent"
        case .video: "film"
        case .web: "globe"
        case .application: "exclamationmark.octagon"
        case .unknown: "questionmark.square.dashed"
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.title, item.type.rawValue]
        if let reason = item.unplayableReason { parts.append("unsupported: \(reason)") }
        return parts.joined(separator: ", ")
    }
}
