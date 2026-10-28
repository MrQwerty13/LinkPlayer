import Foundation
import AVFoundation
import Combine
import LinkPlayerCore

/// Concrete `PlayerControlling` implementation backed by AVPlayer.
/// All calls hop to the main actor; AVPlayer must be used from one thread.
@MainActor
final class AVPlayerEngine: NSObject, PlayerControlling {

    let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemFailedToken: NSObjectProtocol?

    /// Position/duration feed for the SwiftUI scrubber.
    let transport = TransportState()

    override init() {
        super.init()
        transport.currentPlayer = player
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak transport] time in
            let t = time
            Task { @MainActor in transport?.tick(t) }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        statusObservation?.invalidate()
    }

    // MARK: PlayerControlling

    func play(url: URL, onFailure: @escaping @Sendable (PlaybackError) -> Void) async throws {
        stopInternal()

        let item = AVPlayerItem(url: url)
        observe(item, failureHandler: onFailure)
        player.replaceCurrentItem(with: item)
        player.play()
        transport.reset()
    }

    func pause() async { player.pause() }
    func resume() async { player.play() }
    func stop() async { stopInternal() }

    func seek(to seconds: TimeInterval) async {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setVolume(_ volume: Float) async {
        player.volume = min(max(volume, 0), 1)
    }

    // MARK: Helpers

    private func stopInternal() {
        if let token = itemFailedToken {
            NotificationCenter.default.removeObserver(token)
            itemFailedToken = nil
        }
        statusObservation?.invalidate(); statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        transport.reset()
    }

    private func observe(_ item: AVPlayerItem,
                         failureHandler: @escaping @Sendable (PlaybackError) -> Void) {
        // KVO: item-level load failure (unplayable codec, missing file, …)
        statusObservation = item.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed, let err = item.error else { return }
            failureHandler(Self.mapItemError(err))
        }
        // Notification: failure while playing/buffering to end of stream
        itemFailedToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main) { note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            failureHandler(.decodingFailed((err as NSError?)?.localizedDescription ?? "Playback failed"))
        }
    }

    private static func mapItemError(_ error: Error) -> PlaybackError {
        let ns = error as NSError
        if let urlError = error as? URLError {
            return classifyTransportError(urlError)
        }
        // FairPlay / DRM-protected streams surface with a specific OSStatus.
        if ns.code == -11932 ||
           ns.localizedDescription.localizedCaseInsensitiveContains("fairplay") ||
           ns.localizedDescription.localizedCaseInsensitiveContains("drm") {
            return .drmProtected
        }
        return .decodingFailed(ns.localizedDescription)
    }
}

/// Observable transport metrics for the UI (scrubber, time labels).
@MainActor
final class TransportState: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var bufferedFraction: Double = 0

    func tick(_ time: CMTime) {
        guard let player = currentPlayer else { return }
        if time.isNumeric { currentTime = CMTimeGetSeconds(time) }
        guard let item = player.currentItem else { return }
        let d = CMTimeGetSeconds(item.duration)
        if d.isFinite && d > 0 { duration = d }
        let loadedEnd = item.loadedTimeRanges
            .map { CMTimeGetSeconds($0.range.start + $0.range.duration) }
            .max() ?? 0
        bufferedFraction = duration > 0 ? min(loadedEnd / duration, 1) : 0
    }

    func reset() {
        currentTime = 0; duration = 0; bufferedFraction = 0
    }

    /// Set once by the engine; avoids capturing AVPlayer into the observer leak-wise.
    weak var currentPlayer: AVPlayer?
}
