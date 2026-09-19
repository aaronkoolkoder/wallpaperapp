import AppKit
import LibraryKit
import SwiftUI
import WEFormat

/// Sidebar filters.
///
/// Flat rather than hierarchical: a wallpaper library is browsed by "show me the scenes" far
/// more often than by anything that would justify nesting.
enum LibraryFilter: Hashable, Identifiable, CaseIterable {
    case all, scenes, videos, web, unsupported

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All Wallpapers"
        case .scenes: "Scenes"
        case .videos: "Videos"
        case .web: "Web"
        case .unsupported: "Unsupported"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .scenes: "cube.transparent"
        case .videos: "play.rectangle"
        case .web: "globe"
        case .unsupported: "exclamationmark.triangle"
        }
    }

    func matches(_ item: WallpaperItem) -> Bool {
        switch self {
        case .all: true
        case .scenes: item.type == .scene && item.isPlayable
        case .videos: item.type == .video && item.isPlayable
        case .web: item.type == .web && item.isPlayable
        case .unsupported: !item.isPlayable
        }
    }
}

/// The main window: browse the library, inspect a wallpaper, set it.
///
/// Layout follows what a wallpaper library actually needs and what Wallpaper Engine itself
/// established — a filter rail, a dense gallery, and a properties panel for the selection —
/// rendered in Tahoe's language rather than as a port of its chrome.
struct LibraryView: View {
    @Bindable var store: LibraryStore
    var systemModel: WallpaperSystemModel?
    var playlists: PlaylistStore?
    let onPlay: (WallpaperItem) -> Void
    var onPlayOnDisplay: ((WallpaperItem, CGDirectDisplayID) -> Void)?

    @State private var filter: LibraryFilter = .all
    @State private var search = ""
    @State private var selection: WallpaperItem.ID?
    @State private var showsInspector = true
    @State private var showingPlaylists = false
    @State private var showingTutorial = false

    /// Remembers whether the walkthrough has been seen. Held here rather than in the app
    /// delegate because this window is the only place it can appear.
    private let tutorial = TutorialPresentation()

    private var visibleItems: [WallpaperItem] {
        let base = store.items.filter { filter.matches($0) }
        guard !search.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private var selectedItem: WallpaperItem? {
        selection.flatMap { id in store.items.first { $0.id == id } }
    }

    /// Which displays are currently showing the selected wallpaper.
    private var displaysShowingSelection: Set<CGDirectDisplayID> {
        guard let selection, let systemModel else { return [] }
        return Set(
            systemModel.displays.filter { $0.wallpaperID == selection }.map(\.id)
        )
    }

    private var playingIDs: Set<String> {
        Set((systemModel?.displays ?? []).compactMap(\.wallpaperID))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Diorama")
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $showsInspector) {
            InspectorPanel(
                item: selectedItem,
                isPlaying: selectedItem.map { playingIDs.contains($0.id) } ?? false,
                displays: systemModel?.displayTargets ?? [],
                displaysShowingItem: displaysShowingSelection,
                onPlay: { if let item = selectedItem { onPlay(item) } },
                onPlayOnDisplay: { displayID in
                    if let item = selectedItem { onPlayOnDisplay?(item, displayID) }
                },
                onAddToPlaylist: playlists == nil ? nil : { showingPlaylists = true },
                propertyOverrides: selectedItem.map {
                    systemModel?.propertyOverrides(for: $0.id) ?? [:]
                } ?? [:],
                // Nil when there is no engine behind the UI, which is how the offscreen
                // interface renderer gets the panel without live controls.
                onSetProperty: systemModel == nil ? nil : { key, value in
                    if let item = selectedItem {
                        systemModel?.setProperty(value, named: key, on: item.id)
                    }
                },
                onResetProperties: systemModel == nil ? nil : {
                    if let item = selectedItem { systemModel?.resetProperties(on: item.id) }
                }
            )
            .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar { toolbarContent }
        .frame(minWidth: 940, minHeight: 620)
        .sheet(isPresented: $showingTutorial) { tutorialSheet }
        .task {
            // Marked seen on close rather than on show, so quitting mid-walkthrough does not
            // silently burn the one time it appears by itself.
            if tutorial.shouldShowOnLaunch(hasLibrary: store.rootURL != nil) {
                showingTutorial = true
            }
        }
        .sheet(isPresented: $showingPlaylists) {
            if let playlists {
                VStack(spacing: 0) {
                    PlaylistPanel(
                        store: playlists,
                        library: store,
                        selectedWallpaperID: selection
                    )
                    Divider()
                    HStack {
                        Spacer()
                        Button("Done") { showingPlaylists = false }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                }
                .frame(width: 440, height: 420)
            }
        }
        .task { if store.rootURL == nil { store.restore() } }
    }

    private var subtitle: String {
        guard store.rootURL != nil else { return "" }
        if store.isScanning { return "Indexing…" }
        let playable = store.items.filter(\.isPlayable).count
        return "\(playable) playable · \(store.items.count) total"
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $filter) {
            Section("Library") {
                ForEach(LibraryFilter.allCases) { entry in
                    Label(entry.title, systemImage: entry.symbol)
                        .badge(store.items.filter { entry.matches($0) }.count)
                        .tag(entry)
                }
            }

            if let playlists {
                Section("Rotation") {
                    Button {
                        showingPlaylists = true
                    } label: {
                        Label("Playlists", systemImage: "list.bullet.rectangle")
                            .badge(playlists.playlists.count)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.Surface.recessed)
        .navigationSplitViewColumnWidth(min: 212, ideal: 228, max: 300)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            Divider()
            if let root = store.rootURL {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(root.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(root.path)
            }
            HStack(spacing: 6) {
                Button("Choose Folder…", action: chooseFolder)
                    .controlSize(.small)
                Spacer()
                Button {
                    store.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(store.rootURL == nil || store.isScanning)
                .help("Rescan the library")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if store.rootURL == nil {
            EmptyLibraryView(
                onChoose: chooseFolder,
                onShowTutorial: { showingTutorial = true },
                accessError: store.accessError
            )
        } else if store.isScanning && store.items.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Indexing your library…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleItems.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: Design.Grid.minimum, maximum: Design.Grid.maximum),
                        spacing: Design.Space.grid
                    )
                ],
                spacing: Design.Space.grid
            ) {
                ForEach(visibleItems) { item in
                    WallpaperCard(
                        item: item,
                        isSelected: selection == item.id,
                        isPlaying: playingIDs.contains(item.id),
                        onPlay: { onPlay(item) }
                    )
                    .onTapGesture { selection = item.id }
                    .onTapGesture(count: 2) { onPlay(item) }
                }
            }
            .padding(Design.Space.gutter)
        }
        .scrollContentBackground(.hidden)
        .background(Design.Surface.base)
        .searchable(text: $search, placement: .toolbar, prompt: "Search wallpapers")
    }

    // MARK: - Toolbar

    /// Split out of the sheet modifier: as an inline closure the type checker gives up on it.
    private var tutorialSheet: TutorialSheet {
        // The folder picker is offered only when there is nothing imported yet; someone
        // reopening the walkthrough mid-library does not want one sprung on them at the end.
        // Written out rather than as a ternary: a conditional between a method reference and
        // nil is one the type checker will not infer.
        var importAction: (() -> Void)?
        if store.rootURL == nil {
            importAction = { chooseFolder() }
        }
        return TutorialSheet(onImport: importAction) {
            showingTutorial = false
            tutorial.hasBeenSeen = true
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                if let item = selectedItem { onPlay(item) }
            } label: {
                Label("Set as Wallpaper", systemImage: "play.fill")
            }
            .disabled(selectedItem?.isPlayable != true)
            .help("Set the selected wallpaper")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                showingTutorial = true
            } label: {
                Label("How to Import", systemImage: "questionmark.circle")
            }
            .help("Show the import walkthrough again")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose your Wallpaper Engine content folder — "
            + "usually steamapps/workshop/content/431960, copied over from your PC."

        if panel.runModal() == .OK, let url = panel.url {
            store.importLibrary(at: url)
        }
    }
}

/// First run. The wallpapers live on a Windows PC and have to get here somehow, which is this
/// app's single biggest point of friction, so this explains the move concretely rather than
/// showing a bare folder picker and hoping.
struct EmptyLibraryView: View {
    let onChoose: () -> Void
    var onShowTutorial: (() -> Void)?
    var accessError: String?

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Design.Ink.tertiary)

            VStack(spacing: 8) {
                Text("Bring your wallpapers over")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Design.Ink.primary)
                Text("Copy this folder from your PC, then choose it here.")
                    .font(.callout)
                    .foregroundStyle(Design.Ink.secondary)
            }

            Text(verbatim: #"C:\Program Files (x86)\Steam\steamapps\workshop\content\431960"#)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(Design.Ink.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .raisedSurface(radius: Design.Radius.control, fill: Design.Surface.inset)

            Text("AirDrop, a USB drive, or a shared folder all work. Nothing is uploaded "
                 + "anywhere — the files stay on your Mac.")
                .font(.callout)
                .foregroundStyle(Design.Ink.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)

            if let accessError {
                Label(accessError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Design.Status.warning)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }

            HStack(spacing: 12) {
                Button("Choose Folder…", action: onChoose)
                    .controlSize(.extraLarge)
                    .buttonStyle(.borderedProminent)

                if let onShowTutorial {
                    Button("Show Me How", action: onShowTutorial)
                        .controlSize(.extraLarge)
                }
            }
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
