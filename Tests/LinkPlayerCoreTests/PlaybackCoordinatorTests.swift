import XCTest
@testable import LinkPlayerCore

// MARK: - Test doubles (dependency injection)

/// Scriptable fake resolver.
final class MockResolver: URLResolving, @unchecked Sendable {
    enum Behavior {
        case success(contentType: String?, finalURLString: String?, status: Int)
        case failure(PlaybackError)
        case delay(TimeInterval, ResolvedResource)
    }
    private let lock = NSLock()
    private var _behavior: Behavior
    private var _resolveCallCount = 0

    init(behavior: Behavior) { self._behavior = behavior }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var behavior: Behavior {
        get { withLock { _behavior } }
        set { withLock { _behavior = newValue } }
    }

    var resolveCallCount: Int { withLock { _resolveCallCount } }

    func resolve(_ url: URL) async throws -> ResolvedResource {
        withLock { _resolveCallCount += 1 }
        switch behavior {
        case .success(let ct, let final, let status):
            return ResolvedResource(finalURL: URL(string: final ?? url.absoluteString)!,
                                    statusCode: status, contentType: ct)
        case .failure(let error):
            throw error
        case .delay(let interval, let resource):
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            try Task.checkCancellation()
            return resource
        }
    }
}

/// Fake player engine recording calls.
actor FakePlayer: PlayerControlling {
    private(set) var playedURLs: [URL] = []
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    var lastVolume: Float?
    var lastSeek: TimeInterval?
    var playShouldThrow: PlaybackError?
    private var failures: [@Sendable (PlaybackError) -> Void] = []

    /// Lets tests simulate an engine-level failure for the current session.
    func emitEngineFailure(_ error: PlaybackError) {
        for f in failures { f(error) }
    }

    func play(url: URL, onFailure: @escaping @Sendable (PlaybackError) -> Void) async throws {
        if let playShouldThrow { throw playShouldThrow }
        failures = [onFailure] // a new item replaces the previous session's callback
        playedURLs.append(url)
    }
    func pause() async { pauseCount += 1 }
    func resume() async { resumeCount += 1 }
    func stop() async { stopCount += 1; failures.removeAll() }
    func seek(to seconds: TimeInterval) async { lastSeek = seconds }
    func setVolume(_ volume: Float) async { lastVolume = volume }
}

struct StubSettings: SettingsProviding {
    var historyEnabled = true
    var allowsInsecureHTTP = true
    var autoPlayOnOpen = true
    var launchBehavior: LaunchBehavior = .showEmptyPlayer
    var volume: Float = 0.8
}

/// In-memory recorder.
actor MockRecorder: Recording {
    private(set) var recorded: [URL] = []
    func record(url: URL, title: String?) async { recorded.append(url) }
}

final class PlaybackCoordinatorTests: XCTestCase {

    private func makeCoordinator(resolver: URLResolving,
                                 player: FakePlayer,
                                 recorder: MockRecorder? = nil,
                                 settings: SettingsProviding = StubSettings()) -> PlaybackCoordinator {
        let validator = MediaURLValidator(policy: .standard)
        return PlaybackCoordinator(validator: validator,
                                   resolver: resolver,
                                   player: player,
                                   recorder: recorder,
                                   settings: settings)
    }

    /// Waits until phase satisfies predicate or fails on timeout.
    private func waitPhase(_ coordinator: PlaybackCoordinator,
                           timeout: TimeInterval = 2,
                           matching predicate: @escaping (PlaybackPhase) -> Bool) async throws -> PlaybackPhase {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let phase = await coordinator.phase
            if predicate(phase) { return phase }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for phase")
        return await coordinator.phase
    }

    // MARK: Happy path

    func testOpenValidMP4ReachesPlayingState() async throws {
        let player = FakePlayer()
        let resolver = MockResolver(behavior: .success(contentType: "video/mp4", finalURLString: nil, status: 200))
        let recorder = MockRecorder()
        let sut = makeCoordinator(resolver: resolver, player: player, recorder: recorder)

        await sut.open(rawText: "https://cdn.example.com/movie.mp4")
        let phase = try await waitPhase(sut) { if case .playing = $0 { return true }; return false }

        guard case .playing(let url) = phase else { return XCTFail("expected playing") }
        XCTAssertEqual(url.absoluteString, "https://cdn.example.com/movie.mp4")
        let played = await player.playedURLs
        XCTAssertEqual(played.count, 1)
        let recorded = await recorder.recorded
        XCTAssertEqual(recorded.map(\.absoluteString), ["https://cdn.example.com/movie.mp4"])
    }

    func testOpeningNewResourceStopsPreviousOne() async throws {
        let player = FakePlayer()
        let resolver = MockResolver(behavior: .success(contentType: "video/mp4", finalURLString: nil, status: 200))
        let sut = makeCoordinator(resolver: resolver, player: player)

        await sut.open(rawText: "https://example.com/a.mp4")
        _ = try await waitPhase(sut) { if case .playing = $0 { return true }; return false }
        await sut.open(rawText: "https://example.com/b.mp4")
        _ = try await waitPhase(sut) { phase in
            if case .playing(let u) = phase, u.lastPathComponent == "b.mp4" { return true }
            return false
        }

        let stops = await player.stopCount   // at least one stop before second play
        XCTAssertGreaterThanOrEqual(stops, 2) // first open's pre-stop + second open's pre-stop
        let played = await player.playedURLs
        XCTAssertEqual(played.map(\.lastPathComponent), ["a.mp4", "b.mp4"])
    }

    // MARK: Validation failures — no network call

    func testInvalidURLEmitsFailedPhaseWithoutNetwork() async throws {
        let player = FakePlayer()
        let resolver = MockResolver(behavior: .failure(PlaybackError.networkFailure("should not be called")))
        let sut = makeCoordinator(resolver: resolver, player: player)

        await sut.open(rawText: "file:///etc/passwd")
        let phase = try await waitPhase(sut) { if case .failed = $0 { return true }; return false }

        guard case .failed(let error) = phase else { return XCTFail("expected failed") }
        XCTAssertEqual(error, .unsupportedScheme("file"))
        let calls = await resolver.resolveCallCount
        XCTAssertEqual(calls, 0, "must not hit the network for invalid input")
    }

    func testEmptyInputFailsWithEmptyInputError() async throws {
        let sut = makeCoordinator(resolver: MockResolver(behavior: .failure(.cancelled)), player: FakePlayer())
        await sut.open(rawText: "   ")
        let phase = try await waitPhase(sut) { if case .failed = $0 { return true }; return false }
        guard case .failed(let e) = phase else { return XCTFail("expected failed") }
        XCTAssertEqual(e, .emptyInput)
    }

    // MARK: Classification failures

    func testWebPageIsRejectedAsNotAMediaResource() async throws {
        let resolver = MockResolver(behavior: .success(contentType: "text/html; charset=utf-8",
                                                       finalURLString: "https://site.com/watch/123",
                                                       status: 200))
        let player = FakePlayer()
        let sut = makeCoordinator(resolver: resolver, player: player)

        await sut.open(rawText: "https://site.com/watch/123")
        let phase = try await waitPhase(sut) { if case .failed = $0 { return true }; return false }
        guard case .failed(let error) = phase else { return XCTFail("expected failed") }
        XCTAssertEqual(error, .notAMediaResource(finalURL: "https://site.com/watch/123",
                                                 contentType: "text/html; charset=utf-8"))
        let played = await player.playedURLs
        XCTAssertTrue(played.isEmpty, "HTML must never reach the player")
    }

    // MARK: Network errors

    func testNotFoundMapsToReadableError() async throws {
        let resolver = MockResolver(behavior: .failure(.notFound(statusCode: 404)))
        let sut = makeCoordinator(resolver: resolver, player: FakePlayer())
        await sut.open(rawText: "https://example.com/gone.mp4")
        let phase = try await waitPhase(sut) { if case .failed = $0 { return true }; return false }
        guard case .failed(let e) = phase else { return XCTFail("expected failed") }
        XCTAssertEqual(e, .notFound(statusCode: 404))
        XCTAssertNotNil(e.errorDescription)
    }

    func testTimeoutMapsToTimedOut() async throws {
        let resolver = MockResolver(behavior: .failure(.timedOut))
        let sut = makeCoordinator(resolver: resolver, player: FakePlayer())
        await sut.open(rawText: "https://slow.example.com/v.mp4")
        let phase = try await waitPhase(sut) { if case .failed = $0 { return true }; return false }
        guard case .failed(let e) = phase else { return XCTFail("expected failed") }
        XCTAssertEqual(e, .timedOut)
    }

    func testUnauthorizedExplainsNoDRMBypass() async throws {
        let resolver = MockResolver(behavior: .failure(.unauthorized(statusCode: 403)))
        let sut = makeCoordinator(resolver: resolver, player: FakePlayer())
        await sut.open(rawText: "https://private.example.com/v.mp4")
        let phase = try await waitPhase(sut) { if case .failed = $0 { return true }; return false }
        guard case .failed(let e) = phase else { return XCTFail("expected failed") }
        XCTAssertTrue(e.errorDescription!.contains("authorization"))
    }

    // MARK: Cancellation

    func testOpeningSecondLinkCancelsFirstResolve() async throws {
        let slowResource = ResolvedResource(finalURL: URL(string: "https://example.com/slow.mp4")!,
                                            statusCode: 200, contentType: "video/mp4")
        let resolver = MockResolver(behavior: .delay(5, slowResource))
        let player = FakePlayer()
        let sut = makeCoordinator(resolver: resolver, player: player)

        await sut.open(rawText: "https://example.com/slow.mp4")
        // Immediately replace with a fast one.
        resolver.behavior = .success(contentType: "video/mp4",
                                     finalURLString: "https://example.com/fast.mp4", status: 200)
        await sut.open(rawText: "https://example.com/fast.mp4")

        let phase = try await waitPhase(sut, timeout: 3) { phase in
            if case .playing(let u) = phase, u.lastPathComponent == "fast.mp4" { return true }
            return false
        }
        guard case .playing(let u) = phase else { return XCTFail("expected playing fast.mp4") }
        XCTAssertEqual(u.lastPathComponent, "fast.mp4")
        let played = await player.playedURLs
        XCTAssertFalse(played.contains(where: { $0.lastPathComponent == "slow.mp4" }))
    }

    // MARK: Transport controls

    func testTogglePlayPauseTransitionsStates() async throws {
        let resolver = MockResolver(behavior: .success(contentType: "video/mp4", finalURLString: nil, status: 200))
        let player = FakePlayer()
        let sut = makeCoordinator(resolver: resolver, player: player)
        await sut.open(rawText: "https://example.com/m.mp4")
        _ = try await waitPhase(sut) { if case .playing = $0 { return true }; return false }

        await sut.togglePlayPause()
        _ = try await waitPhase(sut) { if case .paused = $0 { return true }; return false }
        await sut.togglePlayPause()
        _ = try await waitPhase(sut) { if case .playing = $0 { return true }; return false }

        let pauses = await player.pauseCount
        let resumes = await player.resumeCount
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(resumes, 1)
    }

    func testStopClearsPlayback() async throws {
        let resolver = MockResolver(behavior: .success(contentType: "video/mp4", finalURLString: nil, status: 200))
        let player = FakePlayer()
        let sut = makeCoordinator(resolver: resolver, player: player)
        await sut.open(rawText: "https://example.com/m.mp4")
        _ = try await waitPhase(sut) { if case .playing = $0 { return true }; return false }
        await sut.stop()
        _ = try await waitPhase(sut) { $0 == .stopped }
    }

    func testSeekAndVolumeForwardToPlayer() async throws {
        let player = FakePlayer()
        let sut = makeCoordinator(resolver: MockResolver(behavior: .failure(.cancelled)), player: player)
        await sut.seek(to: 42)
        await sut.setVolume(0.5)
        let seek = await player.lastSeek
        let vol = await player.lastVolume
        XCTAssertEqual(seek, 42)
        XCTAssertEqual(vol, 0.5)
    }

    // MARK: History policy

    func testHistoryDisabledDoesNotRecord() async throws {
        let resolver = MockResolver(behavior: .success(contentType: "video/mp4", finalURLString: nil, status: 200))
        let recorder = MockRecorder()
        var settings = StubSettings(); settings.historyEnabled = false
        let sut = makeCoordinator(resolver: resolver, player: FakePlayer(), recorder: recorder, settings: settings)
        await sut.open(rawText: "https://example.com/m.mp4")
        _ = try await waitPhase(sut) { if case .playing = $0 { return true }; return false }
        let recorded = await recorder.recorded
        XCTAssertTrue(recorded.isEmpty)
    }

    // MARK: Engine-level failures

    func testEngineFailureAfterStartMovesToFailedPhase() async throws {
        let resolver = MockResolver(behavior: .success(contentType: "video/mp4", finalURLString: nil, status: 200))
        let player = FakePlayer()
        let sut = makeCoordinator(resolver: resolver, player: player)
        await sut.open(rawText: "https://example.com/broken.mp4")
        _ = try await waitPhase(sut) { if case .playing = $0 { return true }; return false }

        await player.emitEngineFailure(.decodingFailed("The media could not be decoded."))
        let phase = try await waitPhase(sut) { if case .failed = $0 { return true }; return false }
        guard case .failed(let e) = phase else { return XCTFail("expected failed") }
        XCTAssertEqual(e, .decodingFailed("The media could not be decoded."))
    }

    func testStaleEngineFailureIsIgnoredAfterStop() async throws {
        let resolver = MockResolver(behavior: .success(contentType: "video/mp4", finalURLString: nil, status: 200))
        let player = FakePlayer()
        let sut = makeCoordinator(resolver: resolver, player: player)
        await sut.open(rawText: "https://example.com/m.mp4")
        _ = try await waitPhase(sut) { if case .playing = $0 { return true }; return false }

        await sut.stop()
        _ = try await waitPhase(sut) { $0 == .stopped }

        // A late callback from the stopped session must not resurrect an error.
        await player.emitEngineFailure(.decodingFailed("late"))
        try await Task.sleep(nanoseconds: 150_000_000)
        let phase = await sut.phase
        XCTAssertEqual(phase, .stopped)
    }
}
