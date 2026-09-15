import AppKit
import Diagnostics
import LibraryKit
import SwiftUI
import WEFormat

/// Properties panel for the selected wallpaper.
///
/// This is where Wallpaper Engine's per-wallpaper settings live, and surfacing them is a real
/// differentiator: a wallpaper recorded to video loses them entirely, which is exactly what the
/// video-conversion apps this project competes with do.
struct InspectorPanel: View {
    @Environment(\.isOffscreenRendering) private var isOffscreenRendering
    let item: WallpaperItem?
    let isPlaying: Bool
    let onPlay: () -> Void

    var body: some View {
        Group {
            if let item {
                content(for: item)
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "square.dashed",
                    description: Text("Choose a wallpaper to see its details.")
                )
            }
        }
        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
    }

    @ViewBuilder
    private func content(for item: WallpaperItem) -> some View {
        // `ScrollView` lays out no content under `ImageRenderer`, so the offscreen harness gets
        // the same stack without the scroller. Same reasoning as the menu bar display list.
        if isOffscreenRendering {
            sections(for: item).padding(Design.Space.card)
        } else {
            ScrollView {
                sections(for: item).padding(Design.Space.card)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func sections(for item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            preview(for: item)
            heading(for: item)
            actions(for: item)

            if !item.isPlayable, let reason = item.unplayableReason {
                unsupportedNotice(reason)
            }

            if !item.tags.isEmpty { tags(for: item) }
            if !item.properties.isEmpty { properties(for: item) }

            details(for: item)
        }
    }

    // MARK: - Sections

    private func preview(for item: WallpaperItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Design.Radius.thumbnail).fill(.quaternary)
            if let url = item.previewURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.appearance.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(Design.Grid.aspect, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Design.Radius.thumbnail))
        .frame(maxWidth: .infinity)
    }

    private func heading(for item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.title)
                .font(.headline)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5) {
                // Monochrome: type is a category, not a status, so it gets a symbol and a tone.
                Chip(text: item.typeLabel, systemImage: item.appearance.symbol)
                if let rating = item.contentRating, rating != "Everyone" {
                    Chip(text: rating, systemImage: "exclamationmark.shield", tint: Design.Status.warning)
                }
                if isPlaying {
                    Chip(
                        text: "Playing", systemImage: "waveform",
                        tint: Design.Status.playing, isProminent: true
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func actions(for item: WallpaperItem) -> some View {
        if isPlaying {
            // A state, not a disabled control. A greyed-out prominent button reads as something
            // you failed to be allowed to press, rather than as something already true.
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("Playing on all displays")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Design.Status.playing)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                Design.Status.playing.opacity(0.12),
                in: .rect(cornerRadius: Design.Radius.control)
            )
        } else {
            Button(action: onPlay) {
                Label("Set as Wallpaper", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!item.isPlayable)
        }
    }

    private func unsupportedNotice(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Design.Status.warning)
            Text(reason)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Status.warning.opacity(0.12), in: .rect(cornerRadius: Design.Radius.chip))
    }

    private func tags(for item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Tags")
            FlowLayout(spacing: 5) {
                ForEach(item.tags, id: \.self) { Chip(text: $0) }
            }
        }
    }

    /// The wallpaper's own user-configurable settings.
    ///
    /// Shown read-only for now: the values parse and display, but editing them has to write back
    /// through to the running scene's uniforms, which is not wired up. Listing them as live
    /// controls that silently did nothing would be worse than showing them as information.
    private func properties(for item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Wallpaper Settings")
            VStack(spacing: 0) {
                ForEach(item.properties.sorted(by: { $0.key < $1.key }), id: \.key) { key, property in
                    PropertyRow(name: property.text ?? key, property: property)
                    if key != item.properties.keys.sorted().last { Divider().opacity(0.4) }
                }
            }
            .raisedSurface(radius: Design.Radius.control, fill: Design.Surface.inset)

            Text("Editing these is not wired up yet.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func details(for item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Details")
            VStack(spacing: 6) {
                DetailRow(label: "Workshop ID", value: item.id)
                if item.sizeBytes > 0 {
                    DetailRow(
                        label: "Size",
                        value: ByteCountFormatter.string(
                            fromByteCount: item.sizeBytes, countStyle: .file
                        )
                    )
                }
                if let modified = item.modifiedAt {
                    DetailRow(
                        label: "Added",
                        value: modified.formatted(date: .abbreviated, time: .omitted)
                    )
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.directory])
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }
}

// MARK: - Pieces

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private struct PropertyRow: View {
    let name: String
    let property: WEProperty

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 10)
            Text(valueDescription)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var valueDescription: String {
        switch property.value {
        case .bool(let flag): flag ? "On" : "Off"
        case .number(let number):
            number == number.rounded()
                ? String(Int(number))
                : String(format: "%.2f", number)
        case .string(let text): text
        case .vector3(let vector):
            String(format: "%.2f, %.2f, %.2f", vector.x, vector.y, vector.z)
        case .null, .none: "—"
        }
    }
}

/// Wrapping row layout for tags. `LazyVGrid` cannot do intrinsic-width wrapping, and a chip row
/// that clips or forces equal columns looks broken next to variable-length tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
