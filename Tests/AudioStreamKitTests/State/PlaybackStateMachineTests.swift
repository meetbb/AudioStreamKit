//
//  PlaybackStateMachineTests.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import XCTest
@testable import AudioStreamKit

// Applicable categories for this component:
// - State transitions (the primary thing this type does)
// - Success paths (idle -> ... -> ended happy path)
// - Failure paths (itemFailed / retryBudgetExhausted -> .failed, and the
//   `canFail` gating that ignores those events from idle/failed/ended)
// - Cancellation (`.cancelled` as a PlaybackError payload; stopRequested
//   as a reset-to-idle "cancel" from any state)
// - Network interruption (networkStallBegan/Recovered, plus the
//   audio-session interruptionBegan/Ended + resumeIntent logic for FR8)
// - Retry behaviour (retryBudgetExhausted transitions, same gating as
//   itemFailed)
//
// Not applicable — intentionally skipped:
// - Concurrency: `PlaybackStateMachine` is a plain synchronous value type
//   with no async/shared-mutable-state behavior of its own to test; any
//   actor-isolation concern belongs to whatever owns an instance of it.
// - Cache behaviour: this type has no knowledge of caching.
// - Resource cleanup: this type owns no resources (no files, sockets,
//   observers, etc.).
final class PlaybackStateMachineTests: XCTestCase {

    // MARK: - Helpers
    //
    // Builds machines into non-idle states by driving them through the
    // public `handle(_:)` API only (never poking `state` directly), so
    // these tests also double as reachability checks for each state.

    private func makeLoading() -> PlaybackStateMachine {
        var machine = PlaybackStateMachine()
        machine.handle(.loadRequested)
        return machine
    }

    private func makeBuffering() -> PlaybackStateMachine {
        var machine = makeLoading()
        machine.handle(.playRequested)
        machine.handle(.itemReady)
        return machine
    }

    private func makePlaying() -> PlaybackStateMachine {
        var machine = makeBuffering()
        machine.handle(.bufferingEnded)
        return machine
    }

    private func makePausedAfterReady() -> PlaybackStateMachine {
        var machine = makeLoading()
        machine.handle(.itemReady)
        return machine
    }

    private func makePausedFromPlaying() -> PlaybackStateMachine {
        var machine = makePlaying()
        machine.handle(.pauseRequested)
        return machine
    }

    private func makeStalled() -> PlaybackStateMachine {
        var machine = makePlaying()
        machine.handle(.networkStallBegan)
        return machine
    }

    private func makeEnded() -> PlaybackStateMachine {
        var machine = makePlaying()
        machine.handle(.itemEnded)
        return machine
    }

    private func makeFailed(_ error: PlaybackError = .decodeFailed) -> PlaybackStateMachine {
        var machine = makeLoading()
        machine.handle(.itemFailed(error))
        return machine
    }

    // MARK: - Success paths / core state transitions

    /// Checks that a brand new player starts out idle, doing nothing.
    func test_initialState_isIdle() {
        let machine = PlaybackStateMachine()
        XCTAssertEqual(machine.state, .idle)
    }

    /// Checks the normal, full journey of playing a track: from idle, through loading and
    /// buffering, to playing, and finally to the track ending.
    func test_happyPath_idleToEnded() {
        var machine = PlaybackStateMachine()
        XCTAssertEqual(machine.handle(.loadRequested), .loading)
        machine.handle(.playRequested)
        XCTAssertEqual(machine.handle(.itemReady), .buffering)
        XCTAssertEqual(machine.handle(.bufferingEnded), .playing)
        XCTAssertEqual(machine.handle(.itemEnded), .ended)
    }

    /// Checks that if a track finishes loading and nobody asked to play it yet, it settles into
    /// paused rather than starting to play on its own.
    func test_loading_itemReady_withoutPriorPlay_goesToPaused() {
        var machine = makeLoading()
        XCTAssertEqual(machine.handle(.itemReady), .paused)
    }

    /// Checks that tapping play then pause while still loading is remembered correctly — once
    /// the track is ready, it lands on paused, not playing.
    func test_loading_playThenPause_thenItemReady_goesToPaused() {
        var machine = makeLoading()
        machine.handle(.playRequested)
        machine.handle(.pauseRequested)
        XCTAssertEqual(machine.handle(.itemReady), .paused)
    }

    /// Checks that loading a new track cancels any earlier "play as soon as it's ready"
    /// request from a previous track.
    func test_loadRequested_resetsAutoPlayIntent() {
        var machine = makeLoading()
        machine.handle(.playRequested)
        machine.handle(.loadRequested)
        XCTAssertEqual(machine.handle(.itemReady), .paused)
    }

    /// Checks that pressing play while paused starts buffering again, on the way to playing.
    func test_paused_playRequested_goesToBuffering() {
        var machine = makePausedFromPlaying()
        XCTAssertEqual(machine.handle(.playRequested), .buffering)
    }

    /// Checks that seeking while playing goes through a brief buffering state, since the
    /// player needs to refill data at the new position.
    func test_playing_seekRequested_goesToBuffering() {
        var machine = makePlaying()
        XCTAssertEqual(machine.handle(.seekRequested), .buffering)
    }

    /// Checks that seeking within a track that already finished playing correctly resumes it
    /// in a paused state, ready to play from the new position.
    func test_ended_seekRequested_goesToPaused() {
        var machine = makeEnded()
        XCTAssertEqual(machine.handle(.seekRequested), .paused)
    }
    
    /// Checks that pressing pause while already paused simply stays paused.
    func test_ended_pauseRequested_goesToPaused() {
        var machine = makePausedFromPlaying()
        XCTAssertEqual(machine.handle(.pauseRequested), .paused)
    }

    /// Checks that after a failure, loading a track again starts a fresh attempt rather than
    /// staying stuck in the failed state.
    func test_failed_loadRequested_allowsRetryFromScratch() {
        var machine = makeFailed()
        XCTAssertEqual(machine.handle(.loadRequested), .loading)
    }

    /// Checks that stopping always works and resets back to idle, no matter what state
    /// playback was in beforehand.
    func test_stopRequested_returnsToIdle_fromAnyNonIdleState() {
        let states: [() -> PlaybackStateMachine] = [
            makeLoading, makeBuffering, makePlaying,
            makePausedFromPlaying, makeStalled, makeEnded, { self.makeFailed() }
        ]
        for makeMachine in states {
            var machine = makeMachine()
            XCTAssertEqual(machine.handle(.stopRequested), .idle)
        }
    }

    /// Checks that events which don't make sense in the current state (like seeking before
    /// anything loaded) are safely ignored instead of causing an unexpected change.
    func test_ignoredEvents_leaveStateUnchanged() {
        var machine = makeLoading()
        XCTAssertEqual(machine.handle(.seekRequested), .loading)

        var playing = makePlaying()
        XCTAssertEqual(playing.handle(.itemReady), .playing)
    }

    // MARK: - Failure paths

    /// Checks that a failure during loading, buffering, playing, paused, or stalled always
    /// correctly moves the player into a failed state.
    func test_itemFailed_fromRetryableStates_movesToFailed() {
        let error = PlaybackError.decodeFailed
        let states: [() -> PlaybackStateMachine] = [
            makeLoading, makeBuffering, makePlaying, makePausedFromPlaying, makeStalled
        ]
        for makeMachine in states {
            var machine = makeMachine()
            XCTAssertEqual(machine.handle(.itemFailed(error)), .failed(error))
        }
    }

    /// Checks that a failure reported while nothing was loaded is ignored, since there's
    /// nothing to fail.
    func test_itemFailed_fromIdle_isIgnored() {
        var machine = PlaybackStateMachine()
        XCTAssertEqual(machine.handle(.itemFailed(.decodeFailed)), .idle)
    }

    /// Checks that once a failure has happened, a second unrelated failure doesn't overwrite
    /// the original error.
    func test_itemFailed_fromFailed_doesNotOverwriteExistingError() {
        var machine = makeFailed(.decodeFailed)
        XCTAssertEqual(machine.handle(.itemFailed(.invalidURL)), .failed(.decodeFailed))
    }

    /// Checks that a failure reported after a track already finished playing is ignored.
    func test_itemFailed_fromEnded_isIgnored() {
        var machine = makeEnded()
        XCTAssertEqual(machine.handle(.itemFailed(.decodeFailed)), .ended)
    }

    // MARK: - Cancellation

    /// Checks that a cancelled request is treated like any other failure and correctly moves
    /// the player into a failed state.
    func test_itemFailed_withCancelledError_isRepresentable() {
        var machine = makePlaying()
        XCTAssertEqual(machine.handle(.itemFailed(.cancelled)), .failed(.cancelled))
    }

    /// Checks that stopping while something is still in progress cancels it outright and
    /// resets to idle, rather than letting it finish first.
    func test_stopRequested_actsAsCancellation_discardingInFlightFailure() {
        var machine = makeBuffering()
        XCTAssertEqual(machine.handle(.stopRequested), .idle)
    }

    // MARK: - Retry behaviour

    /// Checks that once retries have run out during loading, buffering, playing, paused, or
    /// stalled, the player correctly settles into a failed state.
    func test_retryBudgetExhausted_fromRetryableStates_movesToFailed() {
        let error = PlaybackError.network(URLError(.timedOut))
        let states: [() -> PlaybackStateMachine] = [
            makeLoading, makeBuffering, makePlaying, makePausedFromPlaying, makeStalled
        ]
        for makeMachine in states {
            var machine = makeMachine()
            XCTAssertEqual(machine.handle(.retryBudgetExhausted(error)), .failed(error))
        }
    }

    /// Checks that running out of retries is ignored if nothing was loaded or the track
    /// already finished — there's nothing left to fail.
    func test_retryBudgetExhausted_fromIdleOrEnded_isIgnored() {
        var idle = PlaybackStateMachine()
        XCTAssertEqual(idle.handle(.retryBudgetExhausted(.decodeFailed)), .idle)

        var ended = makeEnded()
        XCTAssertEqual(ended.handle(.retryBudgetExhausted(.decodeFailed)), .ended)
    }

    // MARK: - Network interruption (network stalls + audio session interruptions)

    /// Checks that a network hiccup while playing moves to a stalled state, and playback
    /// resumes correctly once the network recovers.
    func test_networkStall_beginsAndRecovers_fromPlaying() {
        var machine = makePlaying()
        XCTAssertEqual(machine.handle(.networkStallBegan), .stalled)
        XCTAssertEqual(machine.handle(.networkStallRecovered), .buffering)
    }

    /// Checks that a network hiccup while buffering (before playback even started) is also
    /// correctly caught as a stall.
    func test_networkStall_beginsFromBuffering() {
        var machine = makeBuffering()
        XCTAssertEqual(machine.handle(.networkStallBegan), .stalled)
    }

    /// Checks that if something interrupts playback (like a phone call), playback correctly
    /// resumes afterward when the system says it's okay to.
    func test_systemInterruption_whilePlaying_resumesAfterEnded_ifShouldResume() {
        var machine = makePlaying()
        XCTAssertEqual(machine.handle(.interruptionBegan), .paused)
        XCTAssertEqual(machine.handle(.interruptionEnded(shouldResume: true)), .buffering)
    }

    /// Checks that if the system says not to resume after an interruption, playback correctly
    /// stays paused instead of restarting on its own.
    func test_systemInterruption_whilePlaying_staysPaused_ifSystemSaysDoNotResume() {
        var machine = makePlaying()
        machine.handle(.interruptionBegan)
        XCTAssertEqual(machine.handle(.interruptionEnded(shouldResume: false)), .paused)
    }

    /// Checks that if the user had already paused manually before an interruption, playback
    /// doesn't auto-resume afterward just because the system allows it.
    func test_systemInterruption_whileAlreadyPaused_doesNotResume() {
        var machine = makePausedFromPlaying()
        machine.handle(.interruptionBegan)
        XCTAssertEqual(machine.handle(.interruptionEnded(shouldResume: true)), .paused)
    }

    /// Checks that if playback was stalled when it got interrupted, it correctly goes back to
    /// buffering afterward rather than resuming as if nothing happened.
    func test_systemInterruption_whileStalled_resumesToBuffering_ifShouldResume() {
        var machine = makeStalled()
        machine.handle(.interruptionBegan)
        XCTAssertEqual(machine.handle(.interruptionEnded(shouldResume: true)), .buffering)
    }

    /// Checks that an interruption while still buffering is handled correctly and playback
    /// returns to buffering afterward.
    func test_systemInterruption_whileBuffering_marksResumeIntent() {
        var machine = makeBuffering()
        machine.handle(.interruptionBegan)
        XCTAssertEqual(machine.handle(.interruptionEnded(shouldResume: true)), .buffering)
    }
}
