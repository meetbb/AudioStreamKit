//
//  AudioPlayerTests.swift
//  AudioStreamKitTests
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import XCTest
@testable import AudioStreamKit

/// Verifies `AudioPlayer`'s delegation to `PlaybackEngine` and its `AsyncStream` wiring, using
/// the internal `init(states:stateContinuation:engine:)` seam to inject an engine built around
/// `TestHTTPServer`/`TestAudioFixture` (a real HTTP server + a real decodable asset) instead of
/// the public init's real `MediaCache`/`MediaSource` stack pointed at a live CDN URL.
final class AudioPlayerTests: XCTestCase {

    private func makePlayer() async throws -> (player: AudioPlayer, server: TestHTTPServer, url: URL) {
        let server = TestHTTPServer()
        try await server.start()
        await server.setResource(.init(body: TestAudioFixture.wav(), mimeType: "audio/wav"), at: "/track.wav")
        let port = await server.port
        let url = URL(string: "http://127.0.0.1:\(port)/track.wav")!

        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mediaSource = MediaSource(mediaCache: MediaCache(rootDirectory: cacheRoot))

        var continuation: AsyncStream<PlaybackState>.Continuation!
        let states = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation, mediaSource: mediaSource)
        let player = AudioPlayer(states: states, stateContinuation: continuation, engine: engine)
        return (player, server, url)
    }

    /// Checks that loading a track works end to end: it starts loading, then settles into a
    /// paused state once ready. Confirms `AudioPlayer.load` actually reaches the real player.
    func test_load_delegatesToEngine_andReachesPaused() async throws {
        let (player, server, url) = try await makePlayer()
        defer { Task { await server.stop() } }

        await player.load(MediaItem(url: url))
        let observed = await collectStates(from: player.states, until: { $0 == .paused })

        XCTAssertEqual(observed, [.loading, .paused])
    }

    /// Checks that tapping play right after loading actually starts playback, even though the
    /// track wasn't ready yet at the moment play was called.
    func test_loadThenPlay_delegatesToEngine_andReachesPlaying() async throws {
        let (player, server, url) = try await makePlayer()
        defer { Task { await server.stop() } }

        await player.load(MediaItem(url: url))
        async let playTask: Void = player.play()
        let observed = await collectStates(from: player.states, until: { $0 == .playing })
        _ = await playTask

        XCTAssertTrue(observed.contains(.playing))
    }

    /// Checks that pausing while a track is playing actually stops it and moves the player into
    /// a paused state.
    func test_pause_afterPlaying_delegatesToEngine_andReachesPaused() async throws {
        let (player, server, url) = try await makePlayer()
        defer { Task { await server.stop() } }

        await player.load(MediaItem(url: url))
        async let playTask: Void = player.play()
        _ = await collectStates(from: player.states, until: { $0 == .playing })
        _ = await playTask

        await player.pause()
        let observed = await collectStates(from: player.states, until: { $0 == .paused })

        XCTAssertEqual(observed, [.paused])
    }

    /// Checks that stopping playback resets the player back to its starting, idle state.
    func test_stop_delegatesToEngine_andReturnsToIdle() async throws {
        let (player, server, url) = try await makePlayer()
        defer { Task { await server.stop() } }

        await player.load(MediaItem(url: url))
        _ = await collectStates(from: player.states, until: { $0 == .paused })

        await player.stop()
        let observed = await collectStates(from: player.states, until: { $0 == .idle })

        XCTAssertEqual(observed, [.idle])
    }

    /// Checks that seeking to a specific point in the track actually moves the playback
    /// position there.
    func test_seek_delegatesToEngine_andMovesCurrentTime() async throws {
        let (player, server, url) = try await makePlayer()
        defer { Task { await server.stop() } }

        await player.load(MediaItem(url: url))
        _ = await collectStates(from: player.states, until: { $0 == .paused })

        await player.seek(to: 1.0)

        let currentTime = await player.currentTime
        XCTAssertEqual(currentTime, 1.0, accuracy: 0.2)
    }

    /// Checks that once a track is loaded, the player reports its real, correct length.
    func test_duration_delegatesToEngine_andReflectsRealAsset() async throws {
        let (player, server, url) = try await makePlayer()
        defer { Task { await server.stop() } }

        await player.load(MediaItem(url: url))
        _ = await collectStates(from: player.states, until: { $0 == .paused })

        let duration = await player.duration
        XCTAssertNotNil(duration)
        XCTAssertEqual(duration ?? 0, 2, accuracy: 0.5)
    }
}
