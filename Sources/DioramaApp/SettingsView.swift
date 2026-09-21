import AppKit
import ServiceManagement
import SwiftUI
import WallpaperKit

// The settings panes. There is no settings window: each pane is a destination in the main
// window's sidebar, listed by `SettingsPane`, so Diorama has exactly one window to find.

// MARK: - General

struct GeneralSettings: View {
    @Bindable var model: WallpaperSystemModel
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Diorama at login", isOn: $launchesAtLogin)
                    .onChange(of: launchesAtLogin) { _, newValue in setLaunchAtLogin(newValue) }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if let root = model.library.rootURL {
                    LabeledContent("Wallpaper folder") {
                        Text(root.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(root.path)
                    }
                    LabeledContent("Wallpapers") {
                        Text("\(model.library.items.count) indexed")
                    }
                    HStack {
                        Button("Rescan") { model.library.rescan() }
                            .disabled(model.library.isScanning)
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([root])
                        }
                    }
                } else {
                    Text("No wallpaper folder chosen yet.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Library")
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            // Revert the toggle so it never claims a state the system did not accept.
            launchesAtLogin = SMAppService.mainApp.status == .enabled
            loginItemError = error.localizedDescription
        }
    }
}

// MARK: - Performance

struct PerformanceSettings: View {
    @Bindable var model: WallpaperSystemModel

    private let frameRates = [15, 24, 30, 60, 120]

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: model.activeCount > 0 ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(model.activeCount > 0 ? .yellow : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.energySummary)
                            .font(.callout.weight(.medium))
                        Text(
                            model.activeCount > 0
                                ? "\(model.activeCount) of \(model.displays.count) display\(model.displays.count == 1 ? "" : "s") drawing"
                                : model.idleReason ?? "Nothing is drawing"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            } header: {
                Text("Right now")
            }

            Section {
                Picker("Plugged in", selection: $model.preferences.frameRateOnAC) {
                    ForEach(frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("On battery", selection: $model.preferences.frameRateOnBattery) {
                    ForEach(frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
            } header: {
                Text("Frame rate")
            } footer: {
                Text("Wallpapers never render faster than their own content asks for.")
                    .font(.caption)
            }

            Section {
                Toggle(
                    "Stop when covered by a window",
                    isOn: $model.preferences.suspendWhenOccluded
                )
                Toggle(
                    "Stop under fullscreen apps",
                    isOn: $model.preferences.suspendUnderFullscreenApps
                )
                Toggle(
                    "Stop in Low Power Mode",
                    isOn: $model.preferences.suspendInLowPowerMode
                )
                Toggle(
                    "Slow down when your Mac gets warm",
                    isOn: $model.preferences.respectThermalPressure
                )
            } header: {
                Text("Saving energy")
            } footer: {
                // This is the single biggest saving in the app, and turning it off is the
                // fastest way to make Diorama expensive. Worth saying plainly.
                Text("A covered wallpaper uses no energy at all. Leaving the first option on is "
                     + "what keeps Diorama close to free when you are working.")
                    .font(.caption)
            }

            Section {
                Toggle("React to system audio", isOn: $model.audioReactivityEnabled)
                if let message = model.audioStatus.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Design.Status.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.audioStatus.isRunning {
                    Label("Listening", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(Design.Status.playing)
                }
            } header: {
                Text("Audio")
            } footer: {
                // Being explicit about the cost: the prompt is the whole price of this feature
                // to someone who does not want it.
                Text("Wallpapers that respond to sound need Screen Recording permission, which "
                     + "is how macOS exposes system audio. Nothing is recorded or saved — only "
                     + "the loudness of each frequency band is read, and only while this is on.")
                    .font(.caption)
            }

            Section {
                Picker("Render quality", selection: $model.preferences.resolutionScale) {
                    Text("Battery saver (50%)").tag(0.5)
                    Text("Balanced (75%)").tag(0.75)
                    Text("Full resolution").tag(1.0)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Quality")
            } footer: {
                Text("Rendering below full resolution and scaling up is a large saving on a "
                     + "high-resolution display, and is hard to see on a background.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Displays

struct DisplaySettings: View {
    @Bindable var model: WallpaperSystemModel

    var body: some View {
        Form {
            ForEach(model.displays) { display in
                Section {
                    LabeledContent("Resolution") {
                        Text("\(Int(display.resolution.width)) × \(Int(display.resolution.height))")
                    }
                    LabeledContent("Wallpaper") {
                        Text(display.wallpaperTitle ?? "None")
                    }
                    LabeledContent("Status") { Text(display.statusText) }

                    if let report = display.report, !report.isFullySupported {
                        DisclosureGroup("Compatibility · \(report.level.label)") {
                            ForEach(report.findings) { finding in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: finding.level == .unsupported
                                          ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(finding.level == .unsupported ? .red : .orange)
                                        .font(.caption)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(finding.feature).font(.caption.weight(.medium))
                                        if let detail = finding.detail {
                                            Text(detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 1)
                            }
                        }
                    }

                    if display.wallpaperTitle != nil {
                        Button("Remove Wallpaper", role: .destructive) {
                            model.clear(display.id)
                        }
                    }
                } header: {
                    HStack {
                        Text(display.name)
                        if display.isMain {
                            Text("Main").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if model.displays.isEmpty {
                ContentUnavailableView(
                    "No displays",
                    systemImage: "display.trianglebadge.exclamationmark"
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 46))
                .foregroundStyle(.tint)

            Text("Diorama").font(.title2.weight(.semibold))
            Text("Version 0.1.0").font(.caption).foregroundStyle(.secondary)

            Text("Plays wallpapers from your Wallpaper Engine library, natively on macOS.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)

            // Nominative use only: describing interoperability is fine, implying affiliation is
            // not. See PLAN.md §11.2.
            Text("Not affiliated with, or endorsed by, Wallpaper Engine or Valve.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Label("Nothing leaves your Mac", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}
