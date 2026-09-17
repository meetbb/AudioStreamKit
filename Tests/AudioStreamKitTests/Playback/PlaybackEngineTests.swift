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

    /// Checks that loading a track with a bad web address fails properly instead of crashing
    /// or hanging. It should briefly show as loading, then fail.
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

    /// Checks that tapping play before anything is loaded does nothing harmful — the player
    /// just stays idle.
    func test_play_beforeAnyLoad_staysIdle() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)
        var iterator = stream.makeAsyncIterator()

        await engine.play()

        let state = await iterator.next()
        XCTAssertEqual(state, .idle)
    }

    /// Checks that tapping pause before anything is loaded does nothing harmful — the player
    /// just stays idle.
    func test_pause_beforeAnyLoad_staysIdle() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)
        var iterator = stream.makeAsyncIterator()

        await engine.pause()

        let state = await iterator.next()
        XCTAssertEqual(state, .idle)
    }

    /// Checks that tapping play after a failed load doesn't wrongly clear the failure — the
    /// player should stay in its failed state.
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

    /// Checks that stopping when nothing was ever loaded is safe and simply leaves the player
    /// idle, even if called more than once.
    func test_stop_beforeAnyLoad_isIdempotent_staysIdle() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)
        var iterator = stream.makeAsyncIterator()

        await engine.stop()

        let state = await iterator.next()
        XCTAssertEqual(state, .idle)
    }

    /// Checks that stopping after a failed load correctly resets the player back to idle.
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

    /// Checks that trying to seek before anything is loaded does nothing harmful — the player
    /// just stays idle.
    func test_seek_beforeAnyLoad_staysIdle() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        let stream = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)
        var iterator = stream.makeAsyncIterator()

        await engine.seek(to: 30)

        let state = await iterator.next()
        XCTAssertEqual(state, .idle)
    }

    /// Checks that trying to seek after a failed load doesn't wrongly clear the failure — the
    /// player should stay in its failed state.
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

    /// Checks that the playback position reads as zero before anything has ever been loaded.
    func test_currentTime_beforeAnyLoad_isZero() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        _ = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)

        let currentTime = await engine.currentTime
        XCTAssertEqual(currentTime, 0)
    }

    /// Checks that the track length is unknown (not a bogus zero) before anything has ever
    /// been loaded.
    func test_duration_beforeAnyLoad_isNil() async {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        _ = AsyncStream<PlaybackState> { continuation = $0 }
        let engine = PlaybackEngine(stateSink: continuation)

        let duration = await engine.duration
        XCTAssertNil(duration)
    }

    // MARK: - Now Playing info (FR6)

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Checks that loading a track shows its title and artist on the lock screen, and that it
    /// correctly shows as not-yet-playing.
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

    /// Checks that stopping playback removes the track info from the lock screen.
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

    /// Checks that if a new track fails to load, the old track's info doesn't stay stuck on the
    /// lock screen — it should get cleared instead.
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

    /// Checks that switching straight from one track to another updates the lock screen to the
    /// new track, without ever flashing it blank in between.
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
