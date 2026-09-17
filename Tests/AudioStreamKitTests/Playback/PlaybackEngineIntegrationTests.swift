//
//  PlaybackEngineIntegrationTests.swift
//  AudioStreamKitTests
//

import XCTest
@testable import AudioStreamKit

/// Exercises `PlaybackEngine.load(_:)`/`play()`/`seek(to:)` against a real `AVPlayer` resolving
/// a real asset over HTTP (`TestHTTPServer` + `TestAudioFixture`) — the gap `PlaybackEngineTests`
/// explicitly defers, since none of its tests reach a resolvable asset. Each test gets its own
/// server/`MediaCache` (a fresh temp directory) so cache state never leaks between tests.
final class PlaybackEngineIntegrationTests: XCTestCase {

    private func makeEngine() async throws -> (engine: PlaybackEngine, states: AsyncStream<PlaybackState>, server: TestHTTPServer, url: URL) {
        let server = TestHTTPServer()
        try await server.start()
        await server.setResource(.init(body: TestAudioFixture.wav(), mimeType: "audio/wav"), at: "/track.wav")
        let port = await server.port
        let url = URL(string: "http://127.0.0.1:\(port)/track.wav")!

        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mediaCache = MediaCache(rootDirectory: cacheRoot)
        let mediaSource = MediaSource(mediaCache: mediaCache)

        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation, mediaSource: mediaSource)
        return (engine, stream, server, url)
    }

    /// Checks that loading a real track from a real server works end to end: it settles into a
    /// paused, ready state, and its real length is correctly reported.
    func test_load_realAsset_reachesPausedOnceReady() async throws {
        let (engine, states, server, url) = try await makeEngine()
        defer { Task { await server.stop() } }

        await engine.load(MediaItem(url: url))
        let observed = await collectStates(from: states, until: { $0 == .paused })

        XCTAssertEqual(observed, [.loading, .paused])

        let duration = await engine.duration
        XCTAssertNotNil(duration)
        XCTAssertEqual(duration ?? 0, 2, accuracy: 0.5)
    }

    /// Checks that tapping play right after loading a real track actually starts real playback,
    /// instead of getting stuck waiting.
    func test_loadThenPlay_realAsset_reachesPlaying() async throws {
        let (engine, states, server, url) = try await makeEngine()
        defer { Task { await server.stop() } }

        await engine.load(MediaItem(url: url))
        async let playTask: Void = engine.play()
        let observed = await collectStates(from: states, until: { $0 == .playing })
        _ = await playTask

        XCTAssertTrue(observed.contains(.playing))
        XCTAssertFalse(observed.contains(.failed(.decodeFailed)))
    }

    /// Checks that seeking to a point in a real, ready track actually moves the playback
    /// position there.
    func test_seekAfterReady_movesCurrentTime() async throws {
        let (engine, states, server, url) = try await makeEngine()
        defer { Task { await server.stop() } }

        await engine.load(MediaItem(url: url))
        _ = await collectStates(from: states, until: { $0 == .paused })

        await engine.seek(to: 1.0)

        let currentTime = await engine.currentTime
        XCTAssertEqual(currentTime, 1.0, accuracy: 0.2)
    }

    /// Checks that if the server hosting a track is completely broken, loading it cleanly
    /// fails instead of hanging forever or crashing.
    func test_load_whenOriginAlwaysFails_reachesFailedState() async throws {
        let (engine, states, server, url) = try await makeEngine()
        defer { Task { await server.stop() } }

        await server.setBehavior(.status(500), sticky: true)

        await engine.load(MediaItem(url: url))
        let observed = await collectStates(from: states, until: {
            if case .failed = $0 { return true }
            return false
        }, timeout: 15)

        XCTAssertTrue(observed.contains(.loading))
        guard case .failed = observed.last else {
            return XCTFail("expected a terminal .failed state, got \(String(describing: observed.last))")
        }
    }
}
