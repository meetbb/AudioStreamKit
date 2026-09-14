//
//  PlaybackEngine.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation
import AVFoundation

/// Owns the real AVFoundation playback session and is the sole bridge between the pure
/// `PlaybackStateMachine` and the outside world: `AVPlayer`, `AVAudioSession`, `MediaSource`,
/// and (eventually) `MPNowPlayingInfoCenter`. `AudioPlayer` (the public facade) talks only to
/// this type; nothing outside `PlaybackEngine` touches AVFoundation directly.
///
/// `actor`, not a plain class (`concurrency-model.md` §2): it owns mutable session state
/// (`player`, `currentItem`, the state machine) that can be touched both by direct commands
/// (`play()`, `pause()`, ...) and by asynchronous AVFoundation callbacks (KVO, notifications)
/// arriving on arbitrary queues — actor isolation serializes all of it automatically, which is
/// what satisfies NFR6 at this boundary.
///
/// THIS FILE IS A SKELETON. Every function's responsibility below is already fixed by the
/// accepted architecture docs it cites — nothing here is a new design decision — but the
/// bodies are `// TODO` until implemented one at a time.
actor PlaybackEngine {

    // MARK: - Dependencies

    /// Fetches/caches media bytes and answers AVFoundation's resource-loading callbacks.
    /// Owned here (not shared with `AudioPlayer`) because only `PlaybackEngine` needs to
    /// drive it — the facade never touches it directly (`public-api.md` §1: internal
    /// subsystems aren't public).
    private let mediaSource: MediaSource

    /// Handed in by `AudioPlayer` at construction rather than `PlaybackEngine` exposing its
    /// own second `AsyncStream` for `AudioPlayer` to forward (`concurrency-model.md` §4) —
    /// avoids a forwarding `Task` and keeps exactly one stream in the whole framework.
    private let stateSink: AsyncStream<PlaybackState>.Continuation

    // MARK: - Session state

    /// The pure decision-making core (`playback-state-machine.md`). `PlaybackEngine` is its
    /// only caller, which is why the machine itself carries no isolation of its own — every
    /// call into it is already serialized by this actor (`concurrency-model.md` §2).
    private var stateMachine = PlaybackStateMachine()

    /// `nil` in `.idle` — there is nothing to hold until `load(_:)` builds a fresh session.
    private var player: AVPlayer?

    /// Held separately from `player.currentItem` so KVO/notification observers can be removed
    /// from the exact instance they were registered on, once `load(_:)`/`stop()` tears it down.
    private var currentItem: AVPlayerItem?

    /// KVO token for `currentItem.status`, removed in `teardownCurrentSession()`.
    private var itemStatusObservation: NSKeyValueObservation?

    /// KVO token for `player.timeControlStatus`, removed in `teardownCurrentSession()`.
    private var timeControlStatusObservation: NSKeyValueObservation?

    // TODO: NotificationCenter tokens (`.AVPlayerItemDidPlayToEndTime`,
    // `AVAudioSession.interruptionNotification`) — same pattern as the two KVO tokens above,
    // once `handleItemDidPlayToEnd`/`handleAudioSessionInterruption` are implemented.

    // MARK: - Init

    init(
        stateSink: AsyncStream<PlaybackState>.Continuation,
        mediaSource: MediaSource = MediaSource()
    ) {
        self.stateSink = stateSink
        self.mediaSource = mediaSource
    }

    // MARK: - Commands (called by AudioPlayer's public methods)

    /// Tears down whatever session is currently active, builds a fresh `AVPlayer`/
    /// `AVPlayerItem` from `mediaSource.makeAsset(for:)`, starts observing it, and drives the
    /// state machine's `.loadRequested` global rule (`playback-state-machine.md` §4) — the
    /// mechanism behind FR13 ("replacing the current item cleanly releases prior resources"):
    /// replacing an item is just calling `load()` again, there is no separate "replace" path.
    func load(_ item: MediaItem) async {
        teardownCurrentSession()
        apply(.loadRequested)

        let asset: AVURLAsset
        do {
            asset = try mediaSource.makeAsset(for: item.url)
        } catch {
            // `makeAsset` only ever throws `.invalidURL` (an unsupported/malformed scheme) —
            // terminal and immediate, never retried (error-handling-strategy.md §4, network
            // layer's `.badURL`/`.unsupportedURL` row applies the same way here).
            apply(.itemFailed((error as? PlaybackError) ?? .invalidURL))
            return
        }

        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        self.currentItem = playerItem
        self.player = player

        startObserving(playerItem)
        await updateNowPlayingInfo(for: item)
    }

    /// Drives `.playRequested`. Only a resume from `.paused` needs a real `player.play()`
    /// call — `.stalled`/`.buffering`/`.playing` all treat the event as redundant (the player
    /// is already trying to play, or already mid-transition toward it), and `.loading` only
    /// records intent via the state machine's internal `autoPlayOnReady` flag, since there's
    /// no player to command yet (`playback-state-machine.md` `.paused`/`.stalled`/`.loading`
    /// rows).
    func play() async {
        let wasPaused = stateMachine.state == .paused
        apply(.playRequested)
        if wasPaused {
            player?.play()
        }
    }

    /// Drives `.pauseRequested` and calls `player?.pause()` unconditionally — pausing a
    /// player that isn't currently playing (e.g. during `.loading`, before one even exists,
    /// since `player` is `Optional`) is a harmless no-op, so there's no need to gate the call
    /// on the resulting state the way `play()` does. Pausing specifically out of `.stalled`
    /// also cancels every `mediaSource`-tracked request for the current item
    /// (`playback-state-machine.md` `.stalled` row, `concurrency-model.md` §6) — nothing is
    /// being consumed while paused, so continuing to retry a stalled fetch would just waste
    /// battery/data for no benefit.
    func pause() async {
        let wasStalled = stateMachine.state == .stalled
        apply(.pauseRequested)
        if wasStalled {
            mediaSource.cancelAll()
        }
        player?.pause()
    }

    /// Drives `.stopRequested` (legal from any state, always lands on `.idle`) and fully tears
    /// down the session: cancels every `mediaSource`-tracked request for the current item
    /// (`concurrency-model.md` §6, `MediaSource.cancelAll()`) and releases the AVPlayer. Tears
    /// down before transitioning — same ordering as `load(_:)` — since there's no new session
    /// to build afterward, just the reset to a clean slate.
    func stop() async {
        teardownCurrentSession()
        apply(.stopRequested)
    }

    /// Drives `.seekRequested`. A mid-play seek always re-buffers
    /// (`playback-state-machine.md` `.playing` row) because AVPlayer must refill data around
    /// the new position; the stale in-flight fetch for the pre-seek position is cancelled by
    /// AVFoundation calling `resourceLoader(_:didCancel:)`, which `MediaSource` already handles
    /// (`streaming-and-caching.md` §5) — `PlaybackEngine` doesn't need to cancel it manually.
    ///
    /// The state machine ignores `.seekRequested` from `.idle`/`.loading`/`.failed` (no known
    /// position yet, or nothing to seek on at all) — mirrored here by skipping the actual
    /// `player.seek(to:)` call in exactly those cases, so we never ask AVPlayer to seek an item
    /// that isn't ready for it.
    func seek(to time: TimeInterval) async {
        let previousState = stateMachine.state
        apply(.seekRequested)

        switch previousState {
        case .idle, .loading, .failed:
            return
        case .buffering, .playing, .paused, .stalled, .ended:
            break
        }

        let target = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        _ = await player?.seek(to: target)
    }

    // MARK: - Pull-based playback info (public-api.md §3)

    /// Reads `player.currentTime()` directly on demand. No push stream / periodic time
    /// observer — FR5 only requires *exposing* position, not streaming live updates
    /// (`public-api.md` §3), so `AudioPlayer.currentTime` just awaits this each time a caller
    /// asks.
    var currentTime: TimeInterval {
        // TODO
        fatalError("not implemented")
    }

    /// `nil` until `currentItem`'s duration becomes known (i.e. before `.itemReady`) — mirrors
    /// `AudioPlayer.duration`'s optionality in the public API.
    var duration: TimeInterval? {
        // TODO
        fatalError("not implemented")
    }

    // MARK: - Turning raw signals into PlaybackEvents (playback-state-machine.md §3)

    /// The single choke point every AVFoundation-derived signal funnels through: hands `event`
    /// to `stateMachine.handle(_:)`, then yields the resulting `PlaybackState` to `stateSink`
    /// (`concurrency-model.md` §4 — `yield` is safe from any context, no forwarding `Task`
    /// needed). Keeping this separate from the signal-detection functions below means "how a
    /// raw signal becomes an event" and "what happens once the state machine reacts" stay two
    /// independently reasoned-about (and testable) concerns.
    private func apply(_ event: PlaybackEvent) {
        let newState = stateMachine.handle(event)
        stateSink.yield(newState)
    }

    /// Observes `currentItem.status` (KVO) for `.readyToPlay` -> `.itemReady`, or `.failed` ->
    /// classifies the underlying `AVError` via `FailureClassifier` and reports
    /// `.itemFailed(PlaybackError)` (`error-handling-strategy.md` §4, Asset layer row —
    /// currently always `.decodeFailed` until real `AVError` codes are distinguished, per
    /// `CURRENT_STATE.md`'s known limitation).
    private func handleItemStatusChange(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            apply(.itemReady)
        case .failed:
            let underlying = item.error ?? PlaybackError.decodeFailed
            apply(.itemFailed(FailureClassifier.classify(underlying).playbackError))
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// Observes `player.timeControlStatus` to report the *benign* buffering signal:
    /// `.waitingToPlayAtSpecifiedRate` -> `.bufferingBegan`, `.playing` -> `.bufferingEnded`.
    /// Deliberately distinct from `handleMediaSourceStallSignal` below — this is AVPlayer
    /// saying "not enough buffered yet," not `MediaSource` saying "a fetch is failing and
    /// retrying" (`playback-state-machine.md` §2, "buffering vs stalled").
    private func handleTimeControlStatusChange(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .waitingToPlayAtSpecifiedRate:
            apply(.bufferingBegan)
        case .playing:
            apply(.bufferingEnded)
        case .paused:
            // Pausing is already driven explicitly by `pause()`/`.interruptionBegan` — this
            // signal would be redundant, and the state machine ignores it anyway wherever it
            // doesn't apply (playback-state-machine.md §1, tolerant of irrelevant events).
            break
        @unknown default:
            break
        }
    }

    /// Reports a `MediaSource`-level transient failure as `.networkStallBegan`/
    /// `.networkStallRecovered`, and a retry-budget exhaustion as
    /// `.retryBudgetExhausted(PlaybackError)` (`playback-state-machine.md` §2,
    /// `error-handling-strategy.md` §2 Tier 1).
    ///
    /// NOT YET WIRED: `MediaSource` doesn't currently expose a stall/exhaustion signal to its
    /// caller at all — its retry loop (`fetchWithRetry` in `MediaSource.swift`) is entirely
    /// private to `fulfillDataRequest`. Making `.stalled`/`.retryBudgetExhausted` real requires
    /// first deciding how `MediaSource` reports this outward (a delegate callback? an
    /// `AsyncStream`? a closure passed at init?) — that's an open design question for when this
    /// function is actually implemented, not something this skeleton should silently invent.
    private func handleMediaSourceStallSignal() {
        // TODO
    }

    /// Observes `NotificationCenter` for `.AVPlayerItemDidPlayToEndTime` on `currentItem` ->
    /// `.itemEnded`.
    private func handleItemDidPlayToEnd() {
        // TODO
    }

    /// Observes `AVAudioSession.interruptionNotification` -> `.interruptionBegan` /
    /// `.interruptionEnded(shouldResume:)`, forwarding the system's
    /// `AVAudioSession.InterruptionOptions.contains(.shouldResume)` bit straight through. The
    /// state machine itself ANDs that with its own `resumeIntent` memory of whether *this app*
    /// was actively playing before the interruption (FR8, `playback-state-machine.md` §6) — the
    /// combining logic belongs there, not here.
    private func handleAudioSessionInterruption(_ notification: Notification) {
        // TODO
    }

    // MARK: - Session lifecycle

    /// Removes every observer `startObserving(_:)` registered and releases `player`/
    /// `currentItem`. Called from both `load(_:)` (before building the new session) and
    /// `stop()`, so "cleanly release resources" (FR13) has exactly one implementation instead
    /// of two copies that could drift apart.
    private func teardownCurrentSession() {
        // TODO: also remove the NotificationCenter tokens once `startObserving(_:)` registers
        // them (`.AVPlayerItemDidPlayToEndTime`, `AVAudioSession.interruptionNotification`).
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        mediaSource.cancelAll()
        player?.pause()
        player = nil
        currentItem = nil
    }

    /// Registers every observer `handleItemStatusChange`/`handleTimeControlStatusChange`/
    /// `handleItemDidPlayToEnd`/`handleAudioSessionInterruption` depend on, against the given
    /// item/player. Symmetric counterpart to `teardownCurrentSession()`.
    private func startObserving(_ item: AVPlayerItem) {
        // KVO delivers on an arbitrary thread, not this actor — hop in via `Task` rather than
        // touching actor state directly from the closure (same bridging pattern `MediaSource`
        // uses for its own AVFoundation callbacks, `concurrency-model.md` §3).
        itemStatusObservation = item.observe(\.status, options: [.new], changeHandler: { [weak self] item, _ in
            guard let self else { return }
            Task(operation: {
                await self.handleItemStatusChange(item)
            })
        })

        // Observed on `player`, not `item` — `timeControlStatus` belongs to AVPlayer itself
        // (playback rate/intent), not the item. `load()` always assigns `self.player` before
        // calling `startObserving`, so it's guaranteed non-nil here.
        timeControlStatusObservation = player?.observe(\.timeControlStatus, options: [.new], changeHandler: { [weak self] player, _ in
            guard let self else { return }
            Task(operation: {
                await self.handleTimeControlStatusChange(player.timeControlStatus)
            })
        })

        // TODO: `.AVPlayerItemDidPlayToEndTime` notification, `AVAudioSession.interruptionNotification`
        // — same bridging pattern as above, once their handler functions are implemented.
    }

    // MARK: - Now Playing / Remote Command Center (FR6)

    /// Publishes `item`'s metadata to `MPNowPlayingInfoCenter`. Explicitly hopped to
    /// `MainActor` at the call site (`concurrency-model.md` §8) — the one narrow exception to
    /// `PlaybackEngine` otherwise needing no particular thread/actor for its own logic.
    private func updateNowPlayingInfo(for item: MediaItem) async {
        // TODO
    }

    /// Registers play/pause/seek handlers on `MPRemoteCommandCenter` so lock-screen/Control
    /// Center controls invoke the same `play()`/`pause()`/`seek(to:)` commands a direct caller
    /// would. Also `MainActor`-hopped, same reasoning as `updateNowPlayingInfo(for:)`.
    private func configureRemoteCommands() async {
        // TODO
    }
}
