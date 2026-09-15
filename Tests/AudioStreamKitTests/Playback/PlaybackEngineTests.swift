//
//  PlaybackEngineTests.swift
//  AudioStreamKitTests
//
//  Created by Meet Brahmbhatt on 14/09/26.
//

import XCTest
import MediaPlayer
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

    // MARK: - Now Playing info (FR6)
    //
    // MPNowPlayingInfoCenter is a real, process-global system singleton, same as
    // MPRemoteCommandCenter — but unlike registering command targets (which would leak
    // duplicate registrations across test runs, the reason `configureRemoteCommands()` has no
    // injectable seam), reading/overwriting `nowPlayingInfo` is safe to do directly: each
    // publish fully replaces the dictionary, so there's nothing to leak between tests beyond
    // the dictionary's own contents, which each test resets before asserting.
    //
    // `refreshNowPlayingInfo()` publishes via a fire-and-forget `Task` hopped to `MainActor` —
    // not awaited by `load()`/`stop()` — so assertions poll with `waitUntil` rather than
    // checking immediately after an `await engine.load(...)`/`await engine.stop()` returns.
    //
    // A valid `https://` URL (vs. the `ftp://` used elsewhere in this file) is needed here so
    // `load(_:)` actually builds an `AVPlayer`/sets `currentMediaItem` and reaches
    // `refreshNowPlayingInfo()` — `https://example.com/...` is the existing convention for this
    // in `MediaSourceTests.swift`; nothing here waits for or depends on the URL ever resolving.

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func test_load_publishesNowPlayingInfo_withTitleArtistAndZeroRate() async {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        var continuation: AsyncStream<PlaybackState>.Continuation!
        _ = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)

        let item = MediaItem(url: URL(string: "https://example.com/track.mp3")!, title: "Song", artist: "Artist")
        await engine.load(item)

        await waitUntil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Song"
        }

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Song")
        XCTAssertEqual(info?[MPMediaItemPropertyArtist] as? String, "Artist")
        // Still .loading in this environment (no resolvable asset) — rate must read 0.0, not
        // 1.0, since nothing is actually playing.
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)
        // duration is unknown while .loading — scrubbing must stay disabled. (The "enabled once
        // duration is known" branch isn't reachable here without a resolvable asset — same
        // network gap noted throughout this file — so it stays integration-test territory.)
        XCTAssertEqual(MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled, false)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func test_stop_afterLoad_clearsNowPlayingInfo() async {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        var continuation: AsyncStream<PlaybackState>.Continuation!
        _ = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)

        await engine.load(MediaItem(url: URL(string: "https://example.com/track.mp3")!, title: "Song"))
        await waitUntil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo != nil
        }

        await engine.stop()
        await waitUntil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo == nil
        }

        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    // Regression test for a bug found in review (findings review, "stale Now Playing info after
    // failed load"): a load(_:) that fails before setting currentMediaItem (invalid URL, or an
    // audio session activation failure) landed on .failed, not .idle — and refreshNowPlayingInfo()'s
    // "should I clear?" check originally only recognized .idle, so the *previous*, unrelated
    // item's info stayed frozen on the lock screen indefinitely after an unrelated load failed.
    func test_load_thatFails_afterSuccessfulLoad_clearsStaleNowPlayingInfo() async {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)
        var iterator = stream.makeAsyncIterator()

        await engine.load(MediaItem(url: URL(string: "https://example.com/track.mp3")!, title: "Song"))
        await waitUntil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Song"
        }
        _ = await iterator.next() // .loading

        await engine.load(MediaItem(url: URL(string: "ftp://example.com/track.mp3")!))
        _ = await iterator.next() // .loading
        let failedState = await iterator.next()
        XCTAssertEqual(failedState, .failed(.invalidURL))

        await waitUntil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo == nil
        }
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    // Regression test for a bug introduced (and caught before shipping) while implementing the
    // clear-on-stop logic: `load(_:)`'s own internal `teardownCurrentSession()` also passes
    // through the "nothing loaded" branch of `refreshNowPlayingInfo()` momentarily (before the
    // new item is set) — that branch must recognize this as `.loading`, not `.idle`, and skip
    // clearing, or every `load(_:)` would flash-clear the lock screen before immediately
    // republishing the new item.
    func test_loadingNewItem_afterAnotherItem_doesNotClear_endsWithNewItemsInfo() async {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        var continuation: AsyncStream<PlaybackState>.Continuation!
        _ = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)

        await engine.load(MediaItem(url: URL(string: "https://example.com/a.mp3")!, title: "Song A"))
        await waitUntil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Song A"
        }

        await engine.load(MediaItem(url: URL(string: "https://example.com/b.mp3")!, title: "Song B"))
        await waitUntil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Song B"
        }

        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Song B")

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

// Remote-command wiring (configureRemoteCommands()) registers directly against the real,
// process-global MPRemoteCommandCenter.shared() — no injectable seam, by design (see session
// discussion: a fake would only exist to serve testability, not the feature itself). That slice
// is verified manually/by integration, not by this suite.
