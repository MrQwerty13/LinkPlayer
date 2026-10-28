import SwiftUI
import AVKit
import LinkPlayerCore

// MARK: - PlayerViewModel (presentation state over the core coordinator)

@MainActor
final class PlayerViewModel: ObservableObject {

    @Published var urlText: String = ""
    @Published var phase: PlaybackPhase = .idle
    @Published var volume: Double = 0.8
    /// Position/duration metrics for the scrubber & time labels.
    let transport: TransportState

    private let coordinator: PlaybackCoordinator
    private let engine: AVPlayerEngine
    private let settings: SettingsProviding

    /// The AVPlayer driving the system player UI (AVPlayerView in AppKit layer).
    var avPlayer: AVPlayer { engine.player }

    init(coordinator: PlaybackCoordinator,
         engine: AVPlayerEngine,
         settings: SettingsProviding) {
        self.coordinator = coordinator
        self.engine = engine
        self.settings = settings
        self.transport = engine.transport
    }

    // MARK: Intent

    func openCurrentInput() {
        open(rawText: urlText)
    }

    func open(rawText: String) {
        let text = rawText
        Task { [coordinator] in
            await coordinator.open(rawText: text)
        }
    }

    func togglePlayPause() {
        Task { [coordinator] in await coordinator.togglePlayPause() }
    }

    func stop() {
        Task { [coordinator] in await coordinator.stop() }
    }

    func seek(to seconds: Double) {
        Task { [coordinator] in await coordinator.seek(to: seconds) }
    }

    func skip(by delta: Double) {
        seek(to: max(0, transport.currentTime + delta))
    }

    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        let v = Float(volume)
        Task { [coordinator] in await coordinator.setVolume(v) }
    }

    func terminate() async {
        await coordinator.stop()
    }

    // MARK: Wiring called once by the app container

    /// Subscribes this view model to coordinator phase transitions and starts
    /// playback according to launch settings. Called from AppContainer.init.
    func startObservingPhaseChanges(applyLaunchBehavior: Bool = false,
                                     lastHistoryURL: String? = nil) async {
        await coordinator.setPhasePublisher { [weak self] newPhase in
            Task { @MainActor in self?.phase = newPhase }
        }
        let stored = await settings.volume
        volume = Double(stored)
        await coordinator.setVolume(stored)

        if applyLaunchBehavior, let last = lastHistoryURL {
            urlText = last
            open(rawText: last)
        }
    }
}
