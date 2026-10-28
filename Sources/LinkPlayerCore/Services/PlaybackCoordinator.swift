import Foundation

/// Transport/playback state machine shared by UI and tests.
public enum PlaybackPhase: Equatable, Sendable {
    case idle
    case validating
    case loading(URL)
    case playing(URL)
    case paused(URL)
    case failed(PlaybackError)
    case stopped

    public var url: URL? {
        switch self {
        case .loading(let u), .playing(let u), .paused(let u): return u
        default: return nil
        }
    }
}

/// Abstraction over the concrete player engine (AVPlayer on macOS).
/// Keeping it a protocol lets us unit-test the whole open→play flow with a fake.
/// Callbacks are passed per-call instead of stored properties so the protocol
/// stays trivially conformable by actors.
public protocol PlayerControlling: Sendable {
    /// Loads and starts playing the given item, fully replacing any current one.
    /// `onFailure` is invoked if the engine fails during playback (decode errors etc.).
    func play(url: URL, onFailure: @escaping @Sendable (PlaybackError) -> Void) async throws
    func pause() async
    func resume() async
    func stop() async
    func seek(to seconds: TimeInterval) async
    func setVolume(_ volume: Float) async
}

/// History sink used by the coordinator.
public protocol Recording: Sendable {
    func record(url: URL, title: String?) async
}

/// Orchestrates: validate → resolve → classify → play → record.
/// Cancellation-safe; opening a new resource always stops the previous one first.
public actor PlaybackCoordinator {

    public private(set) var phase: PlaybackPhase = .idle
    public var onPhaseChange: (@Sendable (PlaybackPhase) -> Void)?

    private let validator: MediaURLValidator
    private let resolver: URLResolving
    private let detector: MediaKindDetector
    private let player: PlayerControlling
    private let recorder: Recording?
    private let settings: SettingsProviding

    private var currentTask: Task<Void, Never>?
    private var taskGeneration: Int = 0

    public init(validator: MediaURLValidator,
                resolver: URLResolving,
                detector: MediaKindDetector = MediaKindDetector(),
                player: PlayerControlling,
                recorder: Recording? = nil,
                settings: SettingsProviding) {
        self.validator = validator
        self.resolver = resolver
        self.detector = detector
        self.player = player
        self.recorder = recorder
        self.settings = settings
    }

    // MARK: - Public API

    /// Entry point from the UI: raw text typed/pasted by the user.
    public func open(rawText: String) {
        currentTask?.cancel()
        taskGeneration += 1
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runOpen(rawText: rawText)
        }
        currentTask = task
    }

    public func togglePlayPause() async {
        switch phase {
        case .playing(let url):
            await player.pause()
            transition(to: .paused(url))
        case .paused:
            await player.resume()
            if let url = phase.url { transition(to: .playing(url)) }
        default:
            break
        }
    }

    public func stop() async {
        currentTask?.cancel()
        currentTask = nil
        taskGeneration += 1
        await player.stop()
        transition(to: .stopped)
    }

    public func seek(to seconds: TimeInterval) async {
        await player.seek(to: seconds)
    }

    public func setVolume(_ volume: Float) async {
        await player.setVolume(volume)
    }

    /// Installs (or removes, with `nil`) the phase-change callback.
    /// Used by the UI layer to mirror actor state into @Published properties.
    public func setPhasePublisher(_ publisher: (@Sendable (PlaybackPhase) -> Void)?) {
        onPhaseChange = publisher
    }

    // MARK: - Flow

    private func runOpen(rawText: String) async {
        // 1. Stop whatever is currently playing before touching the network.
        await player.stop()
        transition(to: .validating)

        do {
            // 2. Cheap synchronous validation of untrusted input.
            let url = try validator.validatedURL(for: rawText)
            try Task.checkCancellation()

            // 3. Resolve redirects & content type without downloading the media.
            transition(to: .loading(url))
            let resolved = try await resolver.resolve(url)
            try Task.checkCancellation()

            // 4. Classify honestly: HTML pages are NOT presented as streams.
            let kind = detector.detect(finalURL: resolved.finalURL,
                                       contentTypeHeader: resolved.contentType)
            guard kind.isDirectlyPlayable else {
                throw PlaybackError.notAMediaResource(finalURL: resolved.finalURL.absoluteString,
                                                      contentType: resolved.contentType)
            }

            // 5. Hand off to the system player. Engine-level failures observed
            // after start are funneled back into this state machine.
            let generation = taskGeneration
            try await player.play(url: resolved.finalURL) { [weak self] error in
                guard let self else { return }
                Task { await self.handleEngineFailure(error, generation: generation) }
            }
            try Task.checkCancellation()
            transition(to: .playing(resolved.finalURL))

            // 6. Local history (device-only, sanitized).
            if await settings.historyEnabled, let recorder {
                await recorder.record(url: resolved.finalURL, title: nil)
            }
        } catch is CancellationError {
            transition(to: .stopped)
        } catch let error as URLError where error.code == .cancelled {
            transition(to: .stopped)
        } catch let error as PlaybackError {
            transition(to: .failed(error))
        } catch {
            transition(to: .failed(classifyTransportError(error)))
        }
    }

    private func handleEngineFailure(_ error: PlaybackError, generation: Int) {
        // Ignore stale callbacks from a previous playback session.
        guard generation == taskGeneration else { return }
        guard case .playing = phase else { return }
        transition(to: .failed(error))
    }

    private func transition(to newPhase: PlaybackPhase) {
        phase = newPhase
        onPhaseChange?(newPhase)
    }
}
