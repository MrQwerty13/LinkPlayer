import SwiftUI
import AVKit
import LinkPlayerCore

// MARK: - Video surface (NSViewRepresentable around the system AVPlayerView)

/// Uses Apple's standard player controls (play/pause, scrubbing, volume,
/// AirPlay, fullscreen/Picture-in-Picture) instead of a custom control layer.
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let phase: PlaybackPhase

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        // Clicking the video toggles playback, like QuickTime.
        view.clickToPlayPauseAllowed = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

// MARK: - History sheet

struct HistoryView: View {
    @EnvironmentObject private var historyVM: HistoryModel
    @EnvironmentObject private var playerVM: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Button("Clear All", role: .destructive) {
                    Task { await historyVM.clear() }
                }
                .disabled(historyVM.entries.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            if historyVM.entries.isEmpty {
                ContentUnavailableCompat(title: "Nothing here yet",
                                         description: "Links you open successfully appear here. History is stored only on this Mac.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(historyVM.entries) { entry in
                        HistoryRow(entry: entry)
                    }
                    .onDelete { indexSet in
                        let ids = indexSet.map { historyVM.entries[$0].id }
                        Task {
                            for id in ids { await historyVM.remove(id) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

struct HistoryRow: View {
    @EnvironmentObject private var playerVM: PlayerViewModel
    @EnvironmentObject private var historyVM: HistoryModel
    let entry: HistoryEntry

    var body: some View {
        Button {
            playerVM.urlText = entry.url
            playerVM.open(rawText: entry.url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.parsedURL.map(LinkPresentation.displayTitle(for:)) ?? entry.url)
                        .lineLimit(1)
                    Text(entry.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(entry.openedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url, forType: .string)
            }
            Divider()
            Button("Remove", role: .destructive) {
                Task { await historyVM.remove(entry.id) }
            }
        }
    }
}

// MARK: - Settings scene content

struct SettingsView: View {
    @EnvironmentObject private var settingsVM: SettingsModel
    @EnvironmentObject private var historyVM: HistoryModel

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Start playing automatically after a link is verified",
                       isOn: $settingsVM.autoPlayOnOpen)
                    .onChange(of: settingsVM.autoPlayOnOpen) { _ in settingsVM.save() }
                Slider(value: $settingsVM.volume, in: 0...1) {
                    Text("Default volume")
                }
                .onChange(of: settingsVM.volume) { _ in settingsVM.save() }
            }

            Section("Privacy & Network") {
                Toggle("Keep a local history of opened links",
                       isOn: $settingsVM.historyEnabled)
                    .onChange(of: settingsVM.historyEnabled) { _ in settingsVM.save() }
                Toggle("Allow plain HTTP links (not encrypted)",
                       isOn: $settingsVM.allowsInsecureHTTP)
                    .onChange(of: settingsVM.allowsInsecureHTTP) { _ in settingsVM.save() }
                Text("LinkPlayer never bypasses DRM or site authorization. Protected streams will fail with a clear message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Picker("On launch:", selection: $settingsVM.launchBehavior) {
                    ForEach(LaunchBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                .onChange(of: settingsVM.launchBehavior) { _ in settingsVM.save() }

                HStack {
                    Button("Clear History Now…", role: .destructive) {
                        Task { await historyVM.clear() }
                    }
                    Button("Reset Settings") {
                        settingsVM.resetToDefaults()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 380)
    }
}

// MARK: - Commands (menu bar)

struct LinkPlayerCommands: Commands {
    var body: some CommandGroup {
        // Note: real shortcuts wired inside each group below.
        CommandGroup(replacing: .newItem) {}
    }
}

// MARK: - Compat helper (ContentUnavailableView exists from macOS 14)

struct ContentUnavailableCompat: View {
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding()
    }
}

// MARK: - Time formatting

enum TimeFormatting {
    /// 0:07 / 1:02:03 style, negative-safe.
    public static func string(seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(seconds.rounded())
        let sign = total < 0 ? "-" : ""
        let t = abs(total)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "\(sign)%d:%02d:%02d", h, m, s)
                     : String(format: "\(sign)%d:%02d", m, s)
    }
}
