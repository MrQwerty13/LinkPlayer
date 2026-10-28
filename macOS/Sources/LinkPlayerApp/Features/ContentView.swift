import SwiftUI
import AVKit
import LinkPlayerCore

// MARK: - Main screen

struct ContentView: View {
    @EnvironmentObject private var playerVM: PlayerViewModel
    @EnvironmentObject private var historyVM: HistoryModel
    @EnvironmentObject private var settingsVM: SettingsModel

    @State private var showHistory = false
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            urlBar
            Divider()
            playerArea
            if let error = currentError {
                errorBanner(error)
            }
            transportBar
        }
        .frame(minWidth: 640, minHeight: 420)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showHistory.toggle()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .help("Recently opened links (\u{2318}Y)")
                .keyboardShortcut("y", modifiers: .command)
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
        }
        .onAppear {
            urlFieldFocused = true
        }
    }

    // MARK: URL input row

    private var urlBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Paste a video link (https://…)", text: $playerVM.urlText)
                .textFieldStyle(.plain)
                .font(.system(body))
                .focused($urlFieldFocused)
                .onSubmit { playerVM.openCurrentInput() }
                .accessibilityLabel("Media URL")
                #if os(macOS)
                .pasteboard(pasting: $playerVM.urlText)
                #endif

            Button("Paste") {
                if let string = NSPasteboard.general.string(forType: .string) {
                    playerVM.urlText = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    playerVM.openCurrentInput()
                }
            }
            .help("Paste from clipboard and play (\u{2318}\u{2325}V)")
            .keyboardShortcut("v", modifiers: [.command, .option])

            Button {
                playerVM.openCurrentInput()
            } label: {
                if playerVM.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(playerVM.urlText.isEmpty || playerVM.isBusy)
            .help("Open the link (Return)")
            .accessibilityLabel("Play")
        }
        .padding(10)
    }

    // MARK: Video area / empty state

    @ViewBuilder
    private var playerArea: some View {
        switch playerVM.phase {
        case .idle, .stopped, .validating where playerVM.avPlayer.currentItem == nil:
            emptyState
        default:
            VideoSurface(player: playerVM.avPlayer, phase: playerVM.phase)
                .overlay(alignment: .top) { loadingOverlay }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No video open")
                .font(.title3.secondary)
            Text("Paste a direct link to an MP4, MOV, audio file or HLS (.m3u8) stream above, then press Return.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        switch playerVM.phase {
        case .validating, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(playerVM.phase == .validating ? "Checking link…" : "Opening stream…")
                    .font(.callout)
            }
            .padding(8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.opacity)
        default:
            EmptyView()
        }
    }

    // MARK: Error banner

    @ViewBuilder
    private func errorBanner(_ error: PlaybackError) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(error.errorDescription ?? "Unknown error")
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button("Dismiss") { playerVM.stop() }
                .buttonStyle(.link)
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .bottom], 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback error")
    }

    private var currentError: PlaybackError? {
        if case .failed(let e) = playerVM.phase { return e }
        return nil
    }

    // MARK: Transport bar (position / duration / volume)

    private var transportBar: some View {
        HStack(spacing: 10) {
            Button {
                playerVM.togglePlayPause()
            } label: {
                Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help(playerVM.isPlaying ? "Pause (Space)" : "Play (Space)")
            .disabled(!playerVM.hasItem)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(playerVM.isPlaying ? "Pause" : "Play")

            Text(TimeFormatting.string(seconds: playerVM.transport.currentTime))
                .monospacedDigit().font(.caption).foregroundStyle(.secondary)

            Slider(value: Binding(
                get: { playerVM.transport.duration > 0 ? playerVM.transport.currentTime : 0 },
                set: { playerVM.seek(to: $0) }
            ), in: 0...max(playerVM.transport.duration, 0.01))
            .disabled(!playerVM.hasItem || playerVM.transport.duration <= 0)
            .accessibilityLabel("Playback position")

            Text(TimeFormatting.string(seconds: playerVM.transport.duration))
                .monospacedDigit().font(.caption).foregroundStyle(.secondary)

            Image(systemName: volumeIcon)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { playerVM.volume },
                set: { playerVM.setVolume($0) }
            ), in: 0...1)
            .frame(width: 90)
            .accessibilityLabel("Volume")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var volumeIcon: String {
        switch playerVM.volume {
        case 0: return "speaker.slash.fill"
        case ..<0.5: return "speaker.fill"
        default: return "speaker.wave.2.fill"
        }
    }
}

// Convenience computed states used by the views.
extension PlayerViewModel {
    var isBusy: Bool {
        switch phase {
        case .validating, .loading: return true
        default: return false
        }
    }
    var isPlaying: Bool {
        if case .playing = phase { return true }
        return false
    }
    var hasItem: Bool {
        switch phase {
        case .playing, .paused, .loading: return true
        default: return false
        }
    }
}
