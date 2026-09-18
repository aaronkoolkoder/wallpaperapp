import LibraryKit
import SwiftUI

/// Create and manage playlists.
///
/// The rotation engine shipped before any way to reach it, which made it a feature that existed
/// only in the source. This is the front door.
struct PlaylistPanel: View {
    @Bindable var store: PlaylistStore
    let library: LibraryStore
    let selectedWallpaperID: String?

    @State private var editing: Playlist?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.card) {
            header

            if store.playlists.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(store.playlists) { playlist in
                        PlaylistRow(
                            playlist: playlist,
                            isActive: store.activePlaylistID == playlist.id,
                            wallpaperCount: playlist.wallpaperIDs.count,
                            onToggleActive: {
                                store.activate(
                                    store.activePlaylistID == playlist.id ? nil : playlist.id
                                )
                            },
                            onEdit: { editing = playlist },
                            onDelete: { store.remove(playlist.id) }
                        )
                    }
                }
            }
        }
        .padding(Design.Space.card)
        .sheet(item: $editing) { playlist in
            PlaylistEditor(
                playlist: playlist,
                library: library,
                onSave: { store.update($0); editing = nil },
                onCancel: { editing = nil }
            )
        }
    }

    private var header: some View {
        HStack {
            SectionLabel("Playlists")
            Spacer()
            Button {
                var playlist = Playlist(name: "New Playlist")
                // Seed with the current selection so creating one from a wallpaper you are
                // looking at does something immediately useful.
                if let selectedWallpaperID { playlist.wallpaperIDs = [selectedWallpaperID] }
                store.add(playlist)
                editing = playlist
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New playlist")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("No playlists yet")
                .font(.callout.weight(.medium))
                .foregroundStyle(Design.Ink.secondary)
            Text("A playlist rotates through wallpapers on a schedule — every few hours, at set "
                 + "times, or when your Mac switches between light and dark.")
                .font(.caption)
                .foregroundStyle(Design.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    let isActive: Bool
    let wallpaperCount: Int
    let onToggleActive: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleActive) {
                Image(systemName: isActive ? "pause.circle.fill" : "play.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isActive ? Design.Status.playing : Design.Ink.secondary)
            }
            .buttonStyle(.plain)
            .help(isActive ? "Stop rotating" : "Start rotating")

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(wallpaperCount) wallpaper\(wallpaperCount == 1 ? "" : "s") · \(playlist.trigger.label)")
                    .font(.caption)
                    .foregroundStyle(Design.Ink.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Menu {
                Button("Edit…", action: onEdit)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(10)
        .raisedSurface(radius: Design.Radius.control, fill: Design.Surface.inset)
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.control)
                .strokeBorder(
                    isActive ? Design.Status.playing.opacity(0.45) : .clear, lineWidth: 1
                )
        }
    }
}

/// Edit one playlist's contents and schedule.
private struct PlaylistEditor: View {
    @State var playlist: Playlist
    let library: LibraryStore
    let onSave: (Playlist) -> Void
    let onCancel: () -> Void

    @State private var triggerKind: TriggerKind
    @State private var intervalMinutes: Double
    @State private var timesOfDay: [Int]

    private enum TriggerKind: String, CaseIterable, Identifiable {
        case interval, timesOfDay, appearance, manual
        var id: Self { self }
        var label: String {
            switch self {
            case .interval: "Every so often"
            case .timesOfDay: "At set times"
            case .appearance: "On light/dark switch"
            case .manual: "Only when I ask"
            }
        }
    }

    init(
        playlist: Playlist,
        library: LibraryStore,
        onSave: @escaping (Playlist) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _playlist = State(initialValue: playlist)
        self.library = library
        self.onSave = onSave
        self.onCancel = onCancel

        switch playlist.trigger {
        case .interval(let seconds):
            _triggerKind = State(initialValue: .interval)
            _intervalMinutes = State(initialValue: max(1, seconds / 60))
            _timesOfDay = State(initialValue: [9 * 60])
        case .timesOfDay(let minutes):
            _triggerKind = State(initialValue: .timesOfDay)
            _intervalMinutes = State(initialValue: 30)
            _timesOfDay = State(initialValue: minutes.isEmpty ? [9 * 60] : minutes)
        case .appearanceChange:
            _triggerKind = State(initialValue: .appearance)
            _intervalMinutes = State(initialValue: 30)
            _timesOfDay = State(initialValue: [9 * 60])
        case .manual:
            _triggerKind = State(initialValue: .manual)
            _intervalMinutes = State(initialValue: 30)
            _timesOfDay = State(initialValue: [9 * 60])
        }
    }

    private var chosen: [WallpaperItem] {
        playlist.wallpaperIDs.compactMap { id in library.items.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $playlist.name)
                    Picker("Order", selection: $playlist.order) {
                        ForEach(PlaylistOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Skip wallpapers that will not render", isOn: $playlist.skipsUnsupported)
                }

                Section("Change wallpaper") {
                    Picker("When", selection: $triggerKind) {
                        ForEach(TriggerKind.allCases) { Text($0.label).tag($0) }
                    }
                    if triggerKind == .interval {
                        LabeledContent("Every") {
                            HStack {
                                Slider(value: $intervalMinutes, in: 1 ... 720, step: 1)
                                Text(intervalDescription)
                                    .font(.callout.monospacedDigit())
                                    .frame(width: 92, alignment: .trailing)
                            }
                        }
                    }
                    if triggerKind == .timesOfDay {
                        ForEach(Array(timesOfDay.enumerated()), id: \.offset) { index, minutes in
                            HStack {
                                DatePicker(
                                    "Time \(index + 1)",
                                    selection: binding(for: index),
                                    displayedComponents: .hourAndMinute
                                )
                                if timesOfDay.count > 1 {
                                    Button {
                                        timesOfDay.remove(at: index)
                                    } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                        Button("Add a time") { timesOfDay.append(18 * 60) }
                            .controlSize(.small)
                    }
                }

                Section("Wallpapers (\(chosen.count))") {
                    if chosen.isEmpty {
                        Text("Add wallpapers from the library with the + on a card.")
                            .font(.caption)
                            .foregroundStyle(Design.Ink.tertiary)
                    } else {
                        // Reorderable, because "in order" is meaningless if the order is fixed.
                        ForEach(chosen) { item in
                            HStack {
                                Text(item.title).lineLimit(1)
                                Spacer()
                                Button {
                                    playlist.wallpaperIDs.removeAll { $0 == item.id }
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        .onMove { source, destination in
                            playlist.wallpaperIDs.move(fromOffsets: source, toOffset: destination)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    playlist.trigger = resolvedTrigger
                    onSave(playlist)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
    }

    private var resolvedTrigger: PlaylistTrigger {
        switch triggerKind {
        case .interval: .interval(seconds: intervalMinutes * 60)
        case .timesOfDay: .timesOfDay(timesOfDay.sorted())
        case .appearance: .appearanceChange
        case .manual: .manual
        }
    }

    private var intervalDescription: String {
        PlaylistTrigger.interval(seconds: intervalMinutes * 60).label
            .replacingOccurrences(of: "Every ", with: "")
    }

    /// Bridges a minutes-past-midnight integer to the `Date` a `DatePicker` wants.
    private func binding(for index: Int) -> Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                let start = calendar.startOfDay(for: Date())
                return calendar.date(
                    byAdding: .minute, value: timesOfDay[index], to: start
                ) ?? start
            },
            set: { newValue in
                let components = Calendar.current.dateComponents(
                    [.hour, .minute], from: newValue
                )
                timesOfDay[index] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }
}
