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
    var displays: [(id: CGDirectDisplayID, name: String)] = []
    var displaysShowingItem: Set<CGDirectDisplayID> = []
    let onPlay: () -> Void
    var onPlayOnDisplay: ((CGDirectDisplayID) -> Void)?
    var onAddToPlaylist: (() -> Void)?

    /// The user's changed settings for this wallpaper, keyed as `project.json` keys them.
    /// Passed in as a value rather than read from the model so the panel stays a pure view.
    var propertyOverrides: [String: DynamicValue] = [:]
    /// nil as the value restores the wallpaper's own.
    var onSetProperty: ((String, DynamicValue?) -> Void)?
    var onResetProperties: (() -> Void)?

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
            PreviewImage(url: item.previewURL, fallbackSymbol: item.appearance.symbol)
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
        VStack(spacing: 8) {
            primaryAction(for: item)

            // Only worth offering when there is more than one display to choose between.
            //
            // `Menu` is one of the views `ImageRenderer` cannot lay out — it draws SwiftUI's
            // cannot-render placeholder and corrupts the layout of everything after it, which
            // is how this was spotted. The offscreen branch keeps the harness meaningful.
            if displays.count > 1, item.isPlayable, isOffscreenRendering {
                Label("Set on One Display", systemImage: "display.2")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .raisedSurface(radius: Design.Radius.control, fill: Design.Surface.inset)
            } else if displays.count > 1, item.isPlayable {
                Menu {
                    Button("All Displays") { onPlay() }
                    Divider()
                    ForEach(displays, id: \.id) { display in
                        Button {
                            onPlayOnDisplay?(display.id)
                        } label: {
                            if displaysShowingItem.contains(display.id) {
                                Label(display.name, systemImage: "checkmark")
                            } else {
                                Text(display.name)
                            }
                        }
                    }
                } label: {
                    Label("Set on One Display", systemImage: "display.2")
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.regular)
            }

            if let onAddToPlaylist, item.isPlayable {
                Button(action: onAddToPlaylist) {
                    Label("Add to a Playlist", systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
            }
        }
    }

    @ViewBuilder
    private func primaryAction(for item: WallpaperItem) -> some View {
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
    /// Live: editing writes through to the running scene's uniforms on the next frame. A
    /// wallpaper that is not playing still records the change, so it applies the moment it is
    /// set. Offscreen interface rendering shows them read-only — the controls do not render.
    private func properties(for item: WallpaperItem) -> some View {
        let keys = item.properties.keys.sorted { left, right in
            // The author's declared order first, falling back to the key so the list is stable
            // for wallpapers that declare none.
            let leftOrder = item.properties[left]?.order ?? Int.max
            let rightOrder = item.properties[right]?.order ?? Int.max
            return leftOrder == rightOrder ? left < right : leftOrder < rightOrder
        }

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Wallpaper Settings")
                Spacer()
                if !propertyOverrides.isEmpty, onResetProperties != nil {
                    Button("Reset All") { onResetProperties?() }
                        .buttonStyle(.plain)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                ForEach(keys, id: \.self) { key in
                    if let property = item.properties[key] {
                        PropertyRow(
                            name: property.text ?? key,
                            key: key,
                            property: property,
                            wallpaperID: item.id,
                            value: propertyOverrides[key] ?? property.value,
                            isCustomised: propertyOverrides[key] != nil,
                            isEditable: !isOffscreenRendering && onSetProperty != nil,
                            onChange: { onSetProperty?(key, $0) }
                        )
                        if key != keys.last { Divider().opacity(0.4) }
                    }
                }
            }
            .raisedSurface(radius: Design.Radius.control, fill: Design.Surface.inset)

            // The binding is by property key, and a wallpaper whose shader uniforms carry no
            // annotation has no key to bind to. Saying so beats a control that does nothing.
            Text("Changes apply immediately. Settings a wallpaper does not bind to a shader have no visible effect.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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

/// One of a wallpaper's settings, as a live control.
///
/// Editing writes through to the running scene's uniforms on the next frame. A wallpaper that is
/// not currently playing still records the change, so it takes effect the moment it is set.
private struct PropertyRow: View {
    let name: String
    let key: String
    let property: WEProperty
    let wallpaperID: String
    let value: DynamicValue?
    let isCustomised: Bool
    let isEditable: Bool
    let onChange: (DynamicValue?) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .font(.caption)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 6)

            if isEditable {
                control
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(maxWidth: 148, alignment: .trailing)
            } else {
                // A control that silently did nothing would be worse than showing the value.
                Text(valueDescription)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Only shown once something has actually been changed, so the row stays quiet until
            // there is something to undo.
            Button {
                onChange(nil)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Restore the wallpaper's own value")
            .opacity(isCustomised ? 1 : 0)
            .disabled(!isCustomised)
            .accessibilityHidden(!isCustomised)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var control: some View {
        switch property.type {
        case .bool:
            Toggle("", isOn: Binding(
                get: { value?.boolValue ?? false },
                set: { onChange(.bool($0)) }
            ))
            .toggleStyle(.switch)

        case .slider:
            sliderControl

        case .color:
            ColorPicker("", selection: Binding(
                get: { colorValue },
                set: { onChange(Self.dynamicValue(from: $0)) }
            ), supportsOpacity: false)

        case .combo:
            Picker("", selection: Binding(
                get: { comboSelection },
                set: { onChange(.number(Double($0))) }
            )) {
                ForEach(Array((property.options ?? []).enumerated()), id: \.offset) { index, option in
                    Text(option.label ?? "Option \(index + 1)")
                        .tag(Self.intValue(of: option.value) ?? index)
                }
            }
            .pickerStyle(.menu)

        case .text, .file, .unknown:
            Text(valueDescription)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Split out of `control`: as one expression inside the switch the type checker gives up.
    private var sliderControl: some View {
        let current = value?.doubleValue ?? property.min ?? 0
        let binding = Binding<Double>(
            get: { current },
            set: { onChange(.number(rounded($0))) }
        )
        return HStack(spacing: 6) {
            Slider(value: binding, in: sliderRange)
                .frame(width: 96)
            Text(String(format: "%.2f", current))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    /// Wallpaper Engine sliders declare their own bounds; a malformed or absent pair would make
    /// SwiftUI's Slider trap, so an empty or inverted range is replaced rather than passed on.
    private var sliderRange: ClosedRange<Double> {
        let low = property.min ?? 0
        let high = property.max ?? 1
        guard low.isFinite, high.isFinite, high > low else { return 0...1 }
        return low...high
    }

    private func rounded(_ raw: Double) -> Double {
        guard let step = property.step, step > 0 else { return raw }
        let low = sliderRange.lowerBound
        return low + ((raw - low) / step).rounded() * step
    }

    private var comboSelection: Int {
        if let current = Self.intValue(of: value) { return current }
        return Self.intValue(of: property.options?.first?.value) ?? 0
    }

    /// Combo values arrive as numbers or as numeric strings depending on the wallpaper.
    static func intValue(of value: DynamicValue?) -> Int? {
        guard let raw = value?.doubleValue, raw.isFinite else { return nil }
        return Int(raw.rounded())
    }

    private var colorValue: Color {
        let components = DioramaColour.components(of: value)
        return Color(.sRGB, red: components.0, green: components.1, blue: components.2)
    }

    /// Wallpaper Engine writes colours as `"r g b"` in 0–1, which is also what a shader wants.
    static func dynamicValue(from color: Color) -> DynamicValue {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return .string(String(
            format: "%.4f %.4f %.4f",
            resolved.redComponent, resolved.greenComponent, resolved.blueComponent
        ))
    }

    private var valueDescription: String {
        switch value {
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

/// Reads a Wallpaper Engine colour value into components.
///
/// The `"r g b"` parsing is `DynamicValue.vector3Value`'s, not a second copy of it — the format
/// already knows how to read one, and two parsers would eventually disagree. What is left here
/// is clamping, and the grey fallback for a colour written as a single number.
enum DioramaColour {
    static func components(of value: DynamicValue?) -> (Double, Double, Double) {
        if let vector = value?.vector3Value {
            return (clamp(vector.x), clamp(vector.y), clamp(vector.z))
        }
        if case .number(let grey) = value {
            return (clamp(grey), clamp(grey), clamp(grey))
        }
        // White rather than black: an unreadable tint that multiplies to nothing would make the
        // layer vanish, while white leaves it as the texture.
        return (1, 1, 1)
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
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
