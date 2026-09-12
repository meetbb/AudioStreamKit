//
//  PlaybackStateMachine.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation

struct PlaybackStateMachine {

    private(set) var state: PlaybackState = .idle

    // Persists across .loading only, so a play()/pause() called before the
    // item is ready is remembered until .itemReady decides where to land.
    private var autoPlayOnReady = false

    // Written only on .interruptionBegan; read once on the matching
    // .interruptionEnded. Captures whether *this app* was actively playing
    // immediately before the interruption (FR8), independent of the
    // system's own shouldResume signal.
    private var resumeIntent = false

    @discardableResult
    mutating func handle(_ event: PlaybackEvent) -> PlaybackState {
        state = nextState(for: event)
        return state
    }

    private mutating func nextState(for event: PlaybackEvent) -> PlaybackState {
        switch state {
        case .idle:
            return handleIdle(event)
        case .loading:
            return handleLoading(event)
        case .buffering:
            return handleBuffering(event)
        case .playing:
            return handlePlaying(event)
        case .paused:
            return handlePaused(event)
        case .stalled:
            return handleStalled(event)
        case .failed:
            return handleFailed(event)
        case .ended:
            return handleEnded(event)
        }
    }

    // MARK: - Per-state transitions

    private mutating func handleIdle(_ event: PlaybackEvent) -> PlaybackState {
        applyGlobal(event) ?? state
    }

    private mutating func handleLoading(_ event: PlaybackEvent) -> PlaybackState {
        switch event {
        case .playRequested:
            autoPlayOnReady = true
            return state
        case .pauseRequested:
            autoPlayOnReady = false
            return state
        case .itemReady:
            return autoPlayOnReady ? .buffering : .paused
        default:
            return applyGlobal(event) ?? state
        }
    }

    private mutating func handleBuffering(_ event: PlaybackEvent) -> PlaybackState {
        switch event {
        case .bufferingEnded:
            return .playing
        case .networkStallBegan:
            return .stalled
        case .pauseRequested:
            return .paused
        case .seekRequested:
            return state
        case .interruptionBegan:
            resumeIntent = true
            return .paused
        case .playRequested:
            return state
        default:
            return applyGlobal(event) ?? state
        }
    }

    private mutating func handlePlaying(_ event: PlaybackEvent) -> PlaybackState {
        switch event {
        case .bufferingBegan:
            return .buffering
        case .networkStallBegan:
            return .stalled
        case .pauseRequested:
            return .paused
        case .seekRequested:
            return .buffering
        case .interruptionBegan:
            resumeIntent = true
            return .paused
        case .itemEnded:
            return .ended
        case .playRequested:
            return state
        default:
            return applyGlobal(event) ?? state
        }
    }

    private mutating func handlePaused(_ event: PlaybackEvent) -> PlaybackState {
        switch event {
        case .playRequested:
            return .buffering
        case .seekRequested:
            return state
        case .interruptionBegan:
            resumeIntent = false
            return state
        case .interruptionEnded(let shouldResume):
            return (shouldResume && resumeIntent) ? .buffering : state
        case .pauseRequested:
            return state
        default:
            return applyGlobal(event) ?? state
        }
    }

    private mutating func handleStalled(_ event: PlaybackEvent) -> PlaybackState {
        switch event {
        case .networkStallRecovered:
            return .buffering
        case .pauseRequested:
            return .paused
        case .seekRequested:
            return .buffering
        case .interruptionBegan:
            resumeIntent = true
            return .paused
        case .playRequested:
            return state
        default:
            return applyGlobal(event) ?? state
        }
    }

    private mutating func handleFailed(_ event: PlaybackEvent) -> PlaybackState {
        applyGlobal(event) ?? state
    }

    private mutating func handleEnded(_ event: PlaybackEvent) -> PlaybackState {
        switch event {
        case .seekRequested:
            return .paused
        default:
            return applyGlobal(event) ?? state
        }
    }

    // MARK: - Global rules (§4)

    /// Returns the resulting state if `event` is one of the three
    /// globally-legal events and applies in the current state, else `nil`
    /// so the caller falls back to "ignored".
    private mutating func applyGlobal(_ event: PlaybackEvent) -> PlaybackState? {
        switch event {
        case .loadRequested:
            autoPlayOnReady = false
            resumeIntent = false
            return .loading

        case .stopRequested:
            return .idle

        case .itemFailed(let error):
            return canFail ? .failed(error) : nil

        case .retryBudgetExhausted(let error):
            return canFail ? .failed(error) : nil

        default:
            return nil
        }
    }

    private var canFail: Bool {
        switch state {
        case .loading, .buffering, .playing, .paused, .stalled:
            return true
        case .idle, .failed, .ended:
            return false
        }
    }
}
