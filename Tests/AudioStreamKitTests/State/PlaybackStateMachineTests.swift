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

    func test_initialState_isIdle() {
        let machine = PlaybackStateMachine()
        XCTAssertEqual(machine.state, .idle)
    }

    func test_happyPath_idleToEnded() {
        var machine = PlaybackStateMachine()
        XCTAssertEqual(machine.handle(.loadRequested), .loading)
        machine.handle(.playRequested)
        XCTAssertEqual(machine.handle(.itemReady), .buffering)
        XCTAssertEqual(machine.handle(.bufferingEnded), .playing)
        XCTAssertEqual(machine.handle(.itemEnded), .ended)
    }

    func test_loading_itemReady_withoutPriorPlay_goesToPaused() {
        var machine = makeLoading()
        XCTAssertEqual(machine.handle(.itemReady), .paused)
    }

    func test_loading_playThenPause_thenItemReady_goesToPaused() {
        var machine = makeLoading()
        machine.handle(.playRequested)
        machine.handle(.pauseRequested)
        XCTAssertEqual(machine.handle(.itemReady), .paused)
    }

    func test_loadRequested_resetsAutoPlayIntent() {
        // playRequested sets autoPlayOnReady=true, but a fresh loadRequested
        // (e.g. loading a new item) must reset it before itemReady fires.
        var machine = makeLoading()
        machine.handle(.playRequested)
        machine.handle(.loadRequested)
        XCTAssertEqual(machine.handle(.itemReady), .paused)
    }

    func test_paused_playRequested_goesToBuffering() {
        var machine = makePausedFromPlaying()
        XCTAssertEqual(machine.handle(.playRequested), .buffering)
    }

    func test_playing_seekRequested_goesToBuffering() {
        var machine = makePlaying()
        XCTAssertEqual(machine.handle(.seekRequested), .buffering)
    }

    func test_ended_seekRequested_goesToPaused() {
        var machine = makeEnded()
        XCTAssertEqual(machine.handle(.seekRequested), .paused)
    }
    
    func test_ended_pauseRequested_goesToPaused() {
        var machine = makePausedFromPlaying()
        XCTAssertEqual(machine.handle(.pauseRequested), .paused)
    }

    func test_failed_loadRequested_allowsRetryFromScratch() {
        var machine = makeFailed()
        XCTAssertEqual(machine.handle(.loadRequested), .loading)
    }

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

    func test_ignoredEvents_leaveStateUnchanged() {
        // seekRequested is not meaningful from `.loading` (nothing to seek
        // in yet) and must be silently ignored rather than crash or move
        // to an unrelated state.
        var machine = makeLoading()
        XCTAssertEqual(machine.handle(.seekRequested), .loading)

        // itemReady is not meaningful once already playing.
        var playing = makePlaying()
        XCTAssertEqual(playing.handle(.itemReady), .playing)
    }

    // MARK: - Failure paths

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

    func test_itemFailed_fromIdle_isIgnored() {
        var machine = PlaybackStateMachine()
        XCTAssertEqual(machine.handle(.itemFailed(.decodeFailed)), .idle)
    }

    func test_itemFailed_fromFailed_doesNotOverwriteExistingError() {
        var machine = makeFailed(.decodeFailed)
        XCTAssertEqual(machine.handle(.itemFailed(.invalidURL)), .failed(.decodeFailed))
    }

    func test_itemFailed_fromEnded_isIgnored() {
        var machine = makeEnded()
        XCTAssertEqual(machine.handle(.itemFailed(.decodeFailed)), .ended)
    }

    // MARK: - Cancellation

    func test_itemFailed_withCancelledError_isRepresentable() {
        // `.cancelled` is just another PlaybackError payload as far as the
        // state machine is concerned — it follows the same canFail gating
        // as any other terminal failure.
        var machine = makePlaying()
        XCTAssertEqual(machine.handle(.itemFailed(.cancelled)), .failed(.cancelled))
    }

    func test_stopRequested_actsAsCancellation_discardingInFlightFailure() {
        // stopRequested from a mid-flight state resets to idle regardless
        // of what would otherwise happen — this is the machine's only
        // "cancel whatever is happening" event.
        var machine = makeBuffering()
        XCTAssertEqual(machine.handle(.stopRequested), .idle)
    }

    // MARK: - Retry behaviour

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

    func test_retryBudgetExhausted_fromIdleOrEnded_isIgnored() {
        var idle = PlaybackStateMachine()
        XCTAssertEqual(idle.handle(.retryBudgetExhausted(.decodeFailed)), .idle)

        var ended = makeEnded()
        XCTAssertEqual(ended.handle(.retryBudgetExhausted(.decodeFailed)), .ended)
    }

    // MARK: - Network interruption (network stalls + audio session interruptions)

    func test_networkStall_beginsAndRecovers_fromPlaying() {
        var machine = makePlaying()
        XCTAssertEqual(machine.handle(.networkStallBegan), .stalled)
        XCTAssertEqual(machine.handle(.networkStallRecovered), .buffering)
    }

    func test_networkStall_beginsFromBuffering() {
        var machine = makeBuffering()
        XCTAssertEqual(machine.handle(.networkStallBegan), .stalled)
    }

    func test_systemInterruption_whilePlaying_resumesAfterEnded_ifShouldResume() {
        var machine = makePlaying()
        XCTAssertEqual(machine.handle(.interruptionBegan), .paused)
        XCTAssertEqual(machine.handle(.interruptionEnded(shouldResume: true)), .buffering)
    }

    func test_systemInterruption_whilePlaying_staysPaused_ifSystemSaysDoNotResume() {
        var machine = makePlaying()
        machine.handle(.interruptionBegan)
        XCTAssertEqual(machine.handle(.interruptionEnded(shouldResume: false)), .paused)
    }

    func test_systemInterruption_whileAlreadyPaused_doesNotResume() {
        // FR8: only resume if playback was active *immediately before* the
        // interruption. If the user had already paused manually, the
        // system's shouldResume=true must not restart playback.
        var machine = makePausedFromPlaying()
        machine.handle(.interruptionBegan)
        XCTAssertEqual(machine.handle(.interruptionEnded(shouldResume: true)), .paused)
    }

    func test_systemInterruption_whileStalled_resumesToBuffering_ifShouldResume() {
        var machine = makeStalled()
        machine.handle(.interruptionBegan)
        XCTAssertEqual(machine.handle(.interruptionEnded(shouldResume: true)), .buffering)
    }

    func test_systemInterruption_whileBuffering_marksResumeIntent() {
        var machine = makeBuffering()
        machine.handle(.interruptionBegan)
        XCTAssertEqual(machine.handle(.interruptionEnded(shouldResume: true)), .buffering)
    }
}
