//
//  PlaybackEngineTests.swift
//  AudioStreamKitTests
//
//  Created by Meet Brahmbhatt on 14/09/26.
//

import XCTest
@testable import AudioStreamKit

/// Scoped to what's testable without a real network fetch or a resolvable `AVAsset` — the
/// happy path of `load(_:)` (reaching `.itemReady`) needs a real or local-server-backed asset,
/// same gap already noted for `MediaSource` in `Documentation/CURRENT_STATE.md`. The
/// unsupported-scheme failure path, however, is synchronous and network-free
/// (`MediaSource.makeAsset` throws before any I/O), so it's fully unit-testable here.
final class PlaybackEngineTests: XCTestCase {

    func test_load_withUnsupportedScheme_reportsLoadingThenInvalidURLFailure() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)
        var iterator = stream.makeAsyncIterator()

        let item = MediaItem(url: URL(string: "ftp://example.com/track.mp3")!)
        await engine.load(item)

        let loadingState = await iterator.next()
        XCTAssertEqual(loadingState, .loading)

        let failedState = await iterator.next()
        XCTAssertEqual(failedState, .failed(.invalidURL))
    }

    // MARK: - play() / pause() ignored paths
    //
    // The "real" branches of play()/pause() (resuming from .paused, cancelling a retry out of
    // .stalled) need a resolved asset to reach those states — same network gap as above. What's
    // testable without one is that calling either command before/without a loaded item is a
    // safe no-op, per the state machine's "ignored" rule (playback-state-machine.md §4) — a
    // realistic scenario (a user tapping play/pause before content has loaded).

    func test_play_beforeAnyLoad_staysIdle() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)
        var iterator = stream.makeAsyncIterator()

        await engine.play()

        let state = await iterator.next()
        XCTAssertEqual(state, .idle)
    }

    func test_pause_beforeAnyLoad_staysIdle() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)
        var iterator = stream.makeAsyncIterator()

        await engine.pause()

        let state = await iterator.next()
        XCTAssertEqual(state, .idle)
    }

    func test_play_afterFailedLoad_staysFailed() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)
        var iterator = stream.makeAsyncIterator()

        await engine.load(MediaItem(url: URL(string: "ftp://example.com/track.mp3")!))
        _ = await iterator.next() // .loading
        _ = await iterator.next() // .failed(.invalidURL)

        await engine.play()

        let state = await iterator.next()
        XCTAssertEqual(state, .failed(.invalidURL))
    }

    // MARK: - stop()

    func test_stop_beforeAnyLoad_isIdempotent_staysIdle() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)
        var iterator = stream.makeAsyncIterator()

        await engine.stop()

        let state = await iterator.next()
        XCTAssertEqual(state, .idle)
    }

    func test_stop_afterFailedLoad_returnsToIdle() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)
        var iterator = stream.makeAsyncIterator()

        await engine.load(MediaItem(url: URL(string: "ftp://example.com/track.mp3")!))
        _ = await iterator.next() // .loading
        _ = await iterator.next() // .failed(.invalidURL)

        await engine.stop()

        let state = await iterator.next()
        XCTAssertEqual(state, .idle)
    }

    // MARK: - seek(to:) ignored paths
    //
    // The "real" branches (an actual `player.seek(to:)` call from `.buffering`/`.playing`/
    // `.paused`/`.stalled`/`.ended`) need a resolved asset to reach those states — same network
    // gap as the rest of this file. What's testable here is that `.idle`/`.loading`/`.failed`
    // ignore the event, per the state machine's rules (playback-state-machine.md `.loading` row
    // note, §4).

    func test_seek_beforeAnyLoad_staysIdle() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)
        var iterator = stream.makeAsyncIterator()

        await engine.seek(to: 30)

        let state = await iterator.next()
        XCTAssertEqual(state, .idle)
    }

    func test_seek_afterFailedLoad_staysFailed() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)
        var iterator = stream.makeAsyncIterator()

        await engine.load(MediaItem(url: URL(string: "ftp://example.com/track.mp3")!))
        _ = await iterator.next() // .loading
        _ = await iterator.next() // .failed(.invalidURL)

        await engine.seek(to: 30)

        let state = await iterator.next()
        XCTAssertEqual(state, .failed(.invalidURL))
    }

    // MARK: - currentTime / duration
    //
    // Only the "no player yet" defaults are testable without a resolved asset — the real
    // values (a genuine position/duration once `.itemReady` fires) need the same network
    // gap noted throughout this file.

    func test_currentTime_beforeAnyLoad_isZero() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        _ = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)

        let currentTime = await engine.currentTime
        XCTAssertEqual(currentTime, 0)
    }

    func test_duration_beforeAnyLoad_isNil() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        _ = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)

        let duration = await engine.duration
        XCTAssertNil(duration)
    }
}
