import AppKit
import LibraryKit
import SwiftUI

/// One page of the import walkthrough.
struct TutorialStep: Identifiable {
    let id: Int
    let symbol: String
    let title: String
    let body: String
    /// Shown in a monospaced, selectable box with a copy button. Used for the Windows path.
    var copyable: String?
    var footnote: String?
}

/// The first-run walkthrough, and the thing the Help button reopens.
///
/// The wallpapers live on a Windows PC and have to physically get to the Mac before anything
/// here works. That is the app's single biggest point of friction and the one step no amount of
/// UI polish elsewhere makes up for, so it is explained as a sequence rather than crammed into
/// an empty-state subtitle.
struct TutorialSheet: View {
    @Environment(\.isOffscreenRendering) private var isOffscreenRendering
    @State private var index: Int
    @State private var copied = false

    /// Called when the user reaches the end and asks to import.
    var onImport: (() -> Void)?
    let onClose: () -> Void

    /// - Parameter startingAt: which page to open on. Only the offscreen interface renderer
    ///   passes anything but zero — it needs each page on its own to check the layout of the
    ///   longest one, and the page index is view state it cannot otherwise reach.
    init(startingAt step: Int = 0, onImport: (() -> Void)? = nil, onClose: @escaping () -> Void) {
        _index = State(initialValue: min(max(0, step), Self.steps.count - 1))
        self.onImport = onImport
        self.onClose = onClose
    }

    static let steps: [TutorialStep] = [
        TutorialStep(
            id: 0,
            symbol: "sparkles.tv",
            title: "Your Wallpaper Engine library, on your Mac",
            body: """
            Diorama plays wallpapers made for Wallpaper Engine — scenes, videos and web \
            wallpapers — natively in Metal, using your own copies.

            It never downloads anything and never connects to Steam. You bring the files; \
            everything happens on this Mac.
            """
        ),
        TutorialStep(
            id: 1,
            symbol: "folder.badge.questionmark",
            title: "Find the folder on your PC",
            body: """
            Wallpaper Engine keeps everything you have subscribed to in one folder, named after \
            its Steam app ID. On most PCs it is here:
            """,
            copyable: #"C:\Program Files (x86)\Steam\steamapps\workshop\content\431960"#,
            footnote: """
            Installed Steam somewhere else? In Wallpaper Engine, right-click any wallpaper and \
            choose “Open in Explorer” — the folder two levels up is the one you want. Each \
            numbered folder inside is a single wallpaper.
            """
        ),
        TutorialStep(
            id: 2,
            symbol: "arrow.left.arrow.right",
            title: "Copy it across",
            body: """
            Move the whole 431960 folder to your Mac. A USB drive, a shared folder, OneDrive or \
            Google Drive all work — whatever you already use.

            Put it somewhere permanent, like your Documents folder. Diorama reads it where it \
            lies and never makes a second copy, so if you move it later it will ask you to \
            point at it again.
            """,
            footnote: """
            Libraries are large. A few hundred wallpapers can be tens of gigabytes, so a cable \
            beats Wi-Fi if you have one.
            """
        ),
        TutorialStep(
            id: 3,
            symbol: "checkmark.circle",
            title: "Point Diorama at it",
            body: """
            Choose the 431960 folder — not a single wallpaper inside it — and Diorama will index \
            everything it can play.

            Pick one and press Set as Wallpaper. Anything that cannot render is listed with the \
            reason rather than quietly skipped.
            """,
            footnote: "You can reopen this walkthrough any time from the Help button."
        ),
    ]

    private var step: TutorialStep { Self.steps[min(index, Self.steps.count - 1)] }
    private var isLast: Bool { index == Self.steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider().overlay(Design.Stroke.subtle)
            controls
        }
        .frame(width: 540, height: 470)
        .background(Design.Surface.base)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: step.symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Design.Ink.secondary)
                .frame(height: 40)

            Text(step.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Design.Ink.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(step.body)
                .font(.callout)
                .foregroundStyle(Design.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let copyable = step.copyable {
                pathBox(copyable)
            }

            if let footnote = step.footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(Design.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(Design.Space.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pathBox(_ path: String) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(Design.Ink.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
                withAnimation(Design.Motion.hover) { copied = true }
            } label: {
                // The label changes rather than a separate confirmation appearing: a toast here
                // would cover the text it is confirming.
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Design.Status.playing : Design.Ink.secondary)
            .help("Copy this path so you can paste it into Explorer on your PC")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .raisedSurface(radius: Design.Radius.control, fill: Design.Surface.inset)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            // Progress as dots rather than "Step 2 of 4": the count is the useful part and it
            // reads at a glance.
            HStack(spacing: 6) {
                ForEach(Self.steps.indices, id: \.self) { position in
                    Circle()
                        .fill(position == index ? Design.Ink.primary : Design.Stroke.strong)
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(index + 1) of \(Self.steps.count)")

            Spacer()

            if index > 0 {
                Button("Back") {
                    withAnimation(Design.Motion.selection) { index -= 1; copied = false }
                }
            }

            if isLast {
                if let onImport {
                    Button("Choose Folder…") { onClose(); onImport() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done", action: onClose)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Next") {
                    withAnimation(Design.Motion.selection) { index += 1; copied = false }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, Design.Space.gutter)
        .padding(.vertical, 14)
    }
}

/// Remembers whether the walkthrough has been shown.
///
/// Its own type rather than a raw `UserDefaults` read at the call site, so "has this been seen"
/// is answered in one place and the Help button can reset it without knowing the key.
@MainActor
final class TutorialPresentation {
    private let defaults: any PreferenceStorage
    private let key = "app.diorama.hasSeenTutorial"

    init(defaults: any PreferenceStorage = UserDefaults.standard) {
        self.defaults = defaults
    }

    var hasBeenSeen: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }

    /// True the first time a library window opens with nothing imported.
    ///
    /// Not shown to someone who already has a library: they have plainly done this before, and
    /// a walkthrough on top of a working app is an interruption rather than help.
    func shouldShowOnLaunch(hasLibrary: Bool) -> Bool {
        !hasBeenSeen && !hasLibrary
    }
}
