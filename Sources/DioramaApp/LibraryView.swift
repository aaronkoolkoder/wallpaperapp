import AppKit
import LibraryKit
import SwiftUI
import WEFormat

/// Sidebar filters. Kept as a flat list rather than a hierarchy: a wallpaper library is browsed
/// by "show me the videos" far more often than by anything that would justify nesting.
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
        case .videos: "film"
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

struct LibraryView: View {
    @Bindable var store: LibraryStore
    let onPlay: (WallpaperItem) -> Void

    @State private var filter: LibraryFilter = .all
    @State private var search = ""
    @State private var selection: WallpaperItem.ID?

    private var visibleItems: [WallpaperItem] {
        let base = store.items.filter { filter.matches($0) }
        guard !search.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Diorama")
        .frame(minWidth: 820, minHeight: 560)
        .task { if store.rootURL == nil { store.restore() } }
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
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        .safeAreaInset(edge: .bottom) { libraryFooter }
    }

    private var libraryFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let root = store.rootURL {
                Text(root.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(root.path)
            }
            HStack {
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
            EmptyLibraryView(onChoose: chooseFolder, accessError: store.accessError)
        } else if store.isScanning && store.items.isEmpty {
            ProgressView("Indexing your library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleItems.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            WallpaperGrid(items: visibleItems, selection: $selection, onPlay: onPlay)
                .searchable(text: $search, placement: .toolbar, prompt: "Search wallpapers")
                .toolbar { scanSummary }
        }
    }

    @ToolbarContentBuilder
    private var scanSummary: some ToolbarContent {
        ToolbarItem(placement: .status) {
            if let scan = store.lastScan {
                Text("\(scan.playableCount) playable · \(store.items.count) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

/// First-run state. This is the app's biggest friction point — the wallpapers live on a Windows
/// PC and have to get here somehow — so it explains the move concretely instead of just showing
/// a folder picker and hoping.
struct EmptyLibraryView: View {
    let onChoose: () -> Void
    var accessError: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)

            VStack(spacing: 8) {
                Text("Bring your wallpapers over")
                    .font(.title2.weight(.semibold))
                Text("Copy this folder from your PC, then choose it here.")
                    .foregroundStyle(.secondary)
            }

            Text(verbatim: #"C:\Program Files (x86)\Steam\steamapps\workshop\content\431960"#)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary, in: .rect(cornerRadius: 8))

            Text("AirDrop, a USB drive, or a shared folder all work. "
                 + "Nothing is uploaded anywhere — the files stay on your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if let accessError {
                Label(accessError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button("Choose Folder…", action: onChoose)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
