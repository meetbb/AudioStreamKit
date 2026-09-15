//
//  PlaybackEngine.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation
import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage

extension PlatformImage {
    /// Renders this image at `size`, used by `publishNowPlayingInfo`'s `MPMediaItemArtwork`
    /// request closure — a real gap, caught in review: that closure used to ignore the size the
    /// system actually asked for and always hand back the full original image, which the lock
    /// screen (wanting a small thumbnail) would just have to downscale itself, wasting memory/CPU
    /// proportional to how much larger the source artwork was than what was actually needed.
    func resized(to size: CGSize) -> PlatformImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage

extension PlatformImage {
    /// AppKit equivalent of the UIKit `resized(to:)` above — same reasoning.
    func resized(to size: CGSize) -> PlatformImage {
        let resized = NSImage(size: size)
        resized.lockFocus()
        draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: self.size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()
        return resized
    }
}
#endif
#if os(iOS)
import os

/// Scoped to this file only — every `AVAudioSession` call that can fail silently (`try?`) or
/// discard its underlying error (`activateAudioSession()`'s rethrow) logs through here instead,
/// so a field report of "audio randomly doesn't work" has something to look at (a real bug,
/// caught in review: this file previously had no logging path at all).
private let logger = Logger(subsystem: "AudioStreamKit", category: "PlaybackEngine")
#endif

/// Owns the real AVFoundation playback session and is the sole bridge between the pure
/// `PlaybackStateMachine` and the outside world: `AVPlayer`, `AVAudioSession`, `MediaSource`,
/// `MPNowPlayingInfoCenter`, and `MPRemoteCommandCenter`. `AudioPlayer` (the public facade)
/// talks only to this type; nothing outside `PlaybackEngine` touches AVFoundation directly.
///
/// `actor`, not a plain class (`concurrency-model.md` §2): it owns mutable session state
/// (`player`, `currentItem`, the state machine) that can be touched both by direct commands
/// (`play()`, `pause()`, ...) and by asynchronous AVFoundation callbacks (KVO, notifications)
/// arriving on arbitrary queues — actor isolation serializes all of it automatically, which is
/// what satisfies NFR6 at this boundary.
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

    /// NotificationCenter token for `AVPlayerItem.didPlayToEndTimeNotification` on
    /// `currentItem`, removed in `teardownCurrentSession()` — and in `deinit`, see below.
    /// `nonisolated(unsafe)`: read from `deinit`, which is implicitly `nonisolated`; `Swift`
    /// can't verify that's safe on its own since `NSObjectProtocol` isn't `Sendable`, but it is
    /// safe here — no concurrent access to `self` is possible once `deinit` begins.
    nonisolated(unsafe) private var didPlayToEndObservation: NSObjectProtocol?

    /// NotificationCenter token for `AVAudioSession.interruptionNotification` — registered once,
    /// for the engine's whole lifetime, by `startObservingAudioSessionInterruptions()` (called
    /// from `init`), not per-item like the observers below. Removed in `deinit`, not on any
    /// per-item teardown. Same `nonisolated(unsafe)` reasoning as `didPlayToEndObservation`.
    nonisolated(unsafe) private var interruptionObservation: NSObjectProtocol?

    /// Removes both `NotificationCenter` tokens still outstanding if this engine is deallocated
    /// without `stop()` having run first (a real gap, caught in review: unlike KVO's
    /// `NSKeyValueObservation`, which auto-invalidates when its token deallocates,
    /// `NotificationCenter.addObserver(forName:object:queue:using:)` does **not** — the caller
    /// is responsible for calling `removeObserver(_:)` explicitly, or the registration and its
    /// closure stay alive in `NotificationCenter` indefinitely). An actor's `deinit` is
    /// implicitly `nonisolated` and can't `await`, but doesn't need to here: reading these
    /// stored properties and calling `removeObserver(_:)` are both safe synchronously — no
    /// concurrent access to `self` is possible once `deinit` begins, and `NotificationCenter`'s
    /// own API is thread-safe. `itemStatusObservation`/`timeControlStatusObservation` (KVO)
    /// need no equivalent handling — `NSKeyValueObservation` invalidates itself automatically.
    deinit {
        if let didPlayToEndObservation {
            NotificationCenter.default.removeObserver(didPlayToEndObservation)
        }
        if let interruptionObservation {
            NotificationCenter.default.removeObserver(interruptionObservation)
        }
    }

    /// The `MediaItem` behind the currently-loaded `currentItem`, retained so `refreshNowPlayingInfo()`
    /// can rebuild the full Now Playing dictionary from every state change, not just at `load(_:)`
    /// time. `nil` whenever `currentItem` is (see `teardownCurrentSession()`).
    private var currentMediaItem: MediaItem?

    /// The last values actually published to `MPNowPlayingInfoCenter`, so `refreshNowPlayingInfo()`
    /// can skip the `MainActor` hop when nothing Now-Playing-relevant has actually changed, rather
    /// than re-publishing on every `PlaybackEvent`. `lastPublishTimestamp` (wall-clock time of
    /// that publish) is what lets `refreshNowPlayingInfo()` tell a real seek (`elapsed` jumps far
    /// from where `lastPublishedRate` would have carried it) apart from ordinary ticking during
    /// continuous playback (`elapsed` lands almost exactly where expected) — see that function's
    /// doc comment for why comparing `elapsed` by raw inequality doesn't work.
    private var lastPublishedRate: Double?
    private var lastPublishedElapsedTime: TimeInterval?
    private var lastPublishedDuration: TimeInterval?
    private var lastPublishTimestamp: Date?

    /// How far `currentTime` may drift from where `lastPublishedRate` would have carried it
    /// before `refreshNowPlayingInfo()` treats that as a real seek rather than ordinary ticking.
    /// 1.5s comfortably clears normal timer/dispatch jitter between events while still catching
    /// any seek a user would actually notice.
    private static let elapsedDiscontinuityThreshold: TimeInterval = 1.5

    /// Whether `MPNowPlayingInfoCenter` currently holds this engine's info — tracked separately
    /// from `lastPublishedRate`/etc. above because `teardownCurrentSession()` resets *those* to
    /// `nil` before `refreshNowPlayingInfo()`'s "should I clear?" check runs, for both `stop()`
    /// and `load(_:)`; this flag survives that reset so the check still works. See
    /// `refreshNowPlayingInfo()`'s doc comment.
    private var isNowPlayingInfoPublished = false

    // MARK: - Init

    init(
        stateSink: AsyncStream<PlaybackState>.Continuation,
        mediaSource: MediaSource = MediaSource()
    ) {
        self.stateSink = stateSink
        self.mediaSource = mediaSource
        // Every stored property is now initialized, so `self` is safe to hand out — this is
        // why `mediaSource.delegate` can't be set via a closure/value captured in the
        // parameter list above (there's no `self` yet at that point), but can be set here.
        mediaSource.delegate = self

        // Fire-and-forget: `init` can't be `async`, and registration doesn't need to complete
        // before `init` returns — a remote command arriving in the brief window before this
        // finishes just doesn't see the registration yet, which is harmless. `[weak self]`
        // guards against `self` being deallocated before either `Task` runs.
        //
        // Interruption observation is registered here too (permanently, for the engine's whole
        // lifetime), not per-item in `startObserving(_:)` as it originally was — a real gap,
        // caught in review: scoping it to "while a session is loaded" meant a `load(_:)` that
        // failed before building a player (e.g. the audio session was unavailable) left the app
        // with no observer at all, so even if whatever was contending for audio then went away,
        // nothing would notice. Interruptions are an app-level, not item-level, concern — there's
        // no `AVPlayerItem` this needs scoping to, unlike the KVO/notification observers
        // `startObserving(_:)` still owns. This does not by itself make a failed `load(_:)`
        // retry automatically — the state machine has no "pending load" concept, and building
        // one is out of scope here — it only ensures the app is listening.
        #if os(iOS)
        Task { [weak self] in await self?.startObservingAudioSessionInterruptions() }
        #endif
        Task { [weak self] in await self?.configureRemoteCommands() }
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

        do {
            try activateAudioSession()
        } catch {
            apply(.itemFailed(.audioSessionUnavailable))
            return
        }

        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        self.currentItem = playerItem
        self.player = player
        self.currentMediaItem = item

        startObserving(playerItem)
        refreshNowPlayingInfo()
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
    ///
    /// The only caller that actually deactivates the audio session — `teardownCurrentSession()`
    /// itself no longer does, since `load(_:)` (its other caller) needs the session to stay
    /// active across an item replacement, not release-then-reclaim it (see that function's
    /// comment).
    func stop() async {
        teardownCurrentSession()
        deactivateAudioSession()
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
    /// asks. `CMTimeGetSeconds` returns `NaN` when there's no player yet or the time isn't
    /// known — treated as `0`, since "nothing has played yet" is a reasonable default (unlike
    /// `duration` below, there's no meaningful "unknown position" to distinguish it from).
    var currentTime: TimeInterval {
        guard let player else { return 0 }
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? seconds : 0
    }

    /// `nil` until `currentItem`'s duration becomes known (i.e. before `.itemReady`) — mirrors
    /// `AudioPlayer.duration`'s optionality in the public API. `CMTimeGetSeconds` returns `NaN`
    /// for an item whose duration isn't known yet, which is the actual signal for "unknown" —
    /// mapped to `nil` rather than `0`, since those mean different things to a caller building
    /// a progress bar.
    var duration: TimeInterval? {
        guard let currentItem else { return nil }
        let seconds = CMTimeGetSeconds(currentItem.duration)
        return seconds.isFinite ? seconds : nil
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
        refreshNowPlayingInfo()
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
    /// `error-handling-strategy.md` §2 Tier 1). Fed by the `MediaSourceDelegate` conformance
    /// below, which is `MediaSource.fetchWithRetry`'s only way to report this outward.
    private func handleMediaSourceStallSignal(_ signal: MediaSourceSignal) {
        switch signal {
        case .stallBegan:
            apply(.networkStallBegan)
        case .stallRecovered:
            apply(.networkStallRecovered)
        case .retryBudgetExhausted(let error):
            apply(.retryBudgetExhausted(error))
        }
    }

    /// Observes `NotificationCenter` for `.AVPlayerItemDidPlayToEndTime` on `currentItem` ->
    /// `.itemEnded`. Only meaningfully changes anything from `.playing` (-> `.ended`,
    /// `playback-state-machine.md` `.playing` row) — the state machine already ignores it
    /// safely from every other state, so there's nothing else for this function to decide.
    private func handleItemDidPlayToEnd() {
        apply(.itemEnded)
    }

    /// Reports `.interruptionBegan` / `.interruptionEnded(shouldResume:)` from a decoded
    /// `AVAudioSession.interruptionNotification`, forwarding the system's
    /// `AVAudioSession.InterruptionOptions.contains(.shouldResume)` bit straight through. The
    /// state machine itself ANDs that with its own `resumeIntent` memory of whether *this app*
    /// was actively playing before the interruption (FR8, `playback-state-machine.md` §6) — the
    /// combining logic belongs there, not here.
    ///
    /// Takes the already-decoded `typeValue`/`optionsValue` raw values, not the `Notification`
    /// itself — `Notification` isn't `Sendable` (its `userInfo` can hold arbitrary non-Sendable
    /// objects), so it can't safely cross into this `Task`-hop under Swift 6's data-race
    /// checking. The registration closure in `startObserving(_:)` decodes the notification
    /// synchronously and hands over only these plain, `Sendable` `UInt`s.
    ///
    /// `PlaybackStateMachine` is pure (`concurrency-model.md` §2) — applying `.interruptionBegan`/
    /// `.interruptionEnded` only computes the *state* that should result, it has no side effect
    /// on the real `AVPlayer`. Translating that into an actual `player.pause()`/`player.play()`
    /// call is this function's job, same as `play()`/`pause()` already do for direct commands —
    /// this was originally missing here entirely (a real bug, caught in review: the state
    /// machine would correctly report `.paused`/`.buffering` and Now Playing would correctly
    /// reflect it, while the real player kept doing whatever it was already doing).
    ///
    /// `#if os(iOS)`: `AVAudioSession` itself is iOS/tvOS/watchOS-only — explicitly unavailable
    /// on macOS, which this package also targets (`Package.swift`). Everywhere else in this
    /// file works identically cross-platform; this is the one function that can't.
    #if os(iOS)
    private func handleAudioSessionInterruption(typeValue: UInt, optionsValue: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            apply(.interruptionBegan)
            // Unconditional, same reasoning as the public `pause()` command: pausing an
            // already-not-playing player is a harmless no-op.
            player?.pause()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            apply(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
            // `.buffering` is only the resulting state when the state machine's own
            // `shouldResume && resumeIntent` check both held (`PlaybackStateMachine`'s
            // `.interruptionEnded` row) — anything else means "stay paused," correctly do
            // nothing. The system can deactivate the audio session during an interruption
            // independently of anything this code does, so the session is explicitly
            // reclaimed before resuming, not assumed still active; if that fails (e.g.
            // something else grabbed exclusive audio in the meantime), report it through the
            // same funnel every other session failure already uses rather than leaving the
            // state machine claiming `.buffering` while nothing actually plays.
            guard stateMachine.state == .buffering else { return }
            do {
                try activateAudioSession()
                player?.play()
            } catch {
                apply(.itemFailed(.audioSessionUnavailable))
            }
        @unknown default:
            break
        }
    }
    #endif

    // MARK: - Session lifecycle

    /// Removes every observer `startObserving(_:)` registered and releases `player`/
    /// `currentItem`. Called from both `load(_:)` (before building the new session) and
    /// `stop()`, so "cleanly release resources" (FR13) has exactly one implementation instead
    /// of two copies that could drift apart.
    private func teardownCurrentSession() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        if let didPlayToEndObservation {
            NotificationCenter.default.removeObserver(didPlayToEndObservation)
        }
        didPlayToEndObservation = nil
        mediaSource.cancelAll()
        player?.pause()
        player = nil
        currentItem = nil
        currentMediaItem = nil
        lastPublishedRate = nil
        lastPublishedElapsedTime = nil
        lastPublishedDuration = nil
        lastPublishTimestamp = nil

        // Deliberately does NOT deactivate the audio session — that used to happen here
        // unconditionally, which meant every `load(_:)` (this function's other caller, for
        // replacing the current item) deactivated-then-immediately-reactivated the session on
        // every single track change. A real bug, caught in review: `.notifyOthersOnDeactivation`
        // explicitly tells other apps "you may resume now," so rapid track skipping in a
        // playlist repeatedly signalled other apps to un-duck and then immediately re-duck —
        // an audible glitch in whatever else happens to be playing. `stop()` is the only place
        // that actually means "give up the speaker," so it deactivates explicitly itself.
        // `load(_:)`'s own `activateAudioSession()` call a few lines later is a safe no-op if
        // the session was already active across the item change.
    }

    /// Registers every observer `handleItemStatusChange`/`handleTimeControlStatusChange`/
    /// `handleItemDidPlayToEnd` depend on, against the given item/player. Symmetric counterpart
    /// to `teardownCurrentSession()`. Interruption observation is *not* registered here — see
    /// `startObservingAudioSessionInterruptions()`.
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

        // `NotificationCenter`, like KVO above, delivers on an arbitrary thread — same `Task`
        // hop. Scoped to `object: item` so a stale notification from a previously-replaced
        // item can never reach this (new) item's handler.
        didPlayToEndObservation = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleItemDidPlayToEnd() }
        }
    }

    /// Registers `AVAudioSession.interruptionNotification` once, for this engine's whole
    /// lifetime — called from `init`'s fire-and-forget `Task`, not from `startObserving(_:)`.
    /// See `init`'s doc comment for why this is scoped to the engine, not the per-item session.
    #if os(iOS)
    private func startObservingAudioSessionInterruptions() {
        // Scoped to `object: AVAudioSession.sharedInstance()` even though there's only ever
        // one shared instance — explicit about its exact source object rather than relying on
        // `nil` (any object) by convention.
        interruptionObservation = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            // Decode synchronously, here, before the `Task` hop — `Notification` isn't
            // `Sendable`, so only the plain `UInt`s extracted from it can safely cross into
            // the actor-isolated handler (see `handleAudioSessionInterruption`'s doc comment).
            guard let self,
                  let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt else {
                return
            }
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task {
                await self.handleAudioSessionInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }
    }
    #endif

    // MARK: - AVAudioSession (iOS only — see `handleAudioSessionInterruption`'s doc comment)

    /// Declares this app as a playback app and claims the speaker. Called from `load(_:)` right
    /// before building the new `AVPlayer`, and again from `handleAudioSessionInterruption`'s
    /// `.ended` case when resuming. Sets the category every time, not just once at `init` —
    /// setting it is cheap and idempotent, and folding it in here removes a real race, caught in
    /// review: category configuration and activation used to be two independently-scheduled
    /// fire-and-forget `Task`s from `init`, with no ordering guarantee between them — a `load(_:)`
    /// called immediately after construction could activate the session before the category had
    /// actually been set, silently activating under whatever category was previously in effect
    /// (e.g. the system default) instead of `.playback`. One call site, always in the right
    /// order, makes the race structurally impossible rather than synchronized around.
    ///
    /// Can fail (e.g. another app holds exclusive audio), in which case the caller reports it
    /// through the same `apply(.itemFailed(...))` funnel every other `load(_:)` failure already
    /// uses. Logs the real underlying error before rethrowing the generic
    /// `.audioSessionUnavailable` — the specific reason (another app has priority vs. a
    /// hardware/category problem, etc.) used to be discarded entirely, leaving no way to
    /// diagnose *why* activation failed in the field.
    #if os(iOS)
    private func activateAudioSession() throws {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("Failed to activate AVAudioSession: \(error.localizedDescription)")
            throw PlaybackError.audioSessionUnavailable
        }
    }

    /// Releases the speaker. The only caller is `stop()` — see `teardownCurrentSession()`'s
    /// comment for why `load(_:)`'s item-replacement path deliberately doesn't deactivate.
    /// `.notifyOthersOnDeactivation` lets a previously-ducked app (one that lowered its own
    /// volume while we were active) know it can resume normally. Best-effort, but logged rather
    /// than silently swallowed, same reasoning as `activateAudioSession()`.
    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("Failed to deactivate AVAudioSession: \(error.localizedDescription)")
        }
    }
    #else
    // No-op stubs on platforms without `AVAudioSession` (macOS) — there's no speaker to
    // claim/release, but `load(_:)`/`stop()`/`teardownCurrentSession()` call these
    // unconditionally rather than wrapping each call site in its own `#if os(iOS)`. A real
    // readability gap, caught in review: scattering platform conditionals through the methods
    // that most need to stay easy to scan (`load(_:)` especially) was worse than concentrating
    // the platform difference here, at the one place it's unavoidable.
    private func activateAudioSession() throws {}
    private func deactivateAudioSession() {}
    #endif

    // MARK: - Now Playing / Remote Command Center (FR6)

    /// Recomputes the Now-Playing-relevant `(rate, elapsedTime, duration)` tuple from current
    /// state and, only if it actually represents a real change, hands it off to
    /// `publishNowPlayingInfo` to write. Called from `apply(_:)` after every `PlaybackEvent`
    /// (not a hand-picked subset — see `Documentation/CURRENT_STATE.md`/design discussion: a
    /// picked list of "which events matter" drifts as events get added) and from `load(_:)`
    /// directly (its own `apply(.loadRequested)` fires before `currentMediaItem` is set, so it
    /// needs a second call after).
    ///
    /// "Real change" is `rate`/`duration` differing from what was last published, OR `elapsed`
    /// landing somewhere other than where it should, given `lastPublishedRate` and how much
    /// wall-clock time has passed since `lastPublishTimestamp` — i.e. an actual seek, not just
    /// ordinary ticking. Comparing `elapsed` by raw inequality (a prior version's approach — a
    /// real bug, caught in review) doesn't work: `currentTime` strictly increases while
    /// `.playing`, so it differs from the last published value on essentially every call,
    /// defeating the dedup precisely when it matters most — a burst of `.networkStallBegan`/
    /// `.networkStallRecovered` events on a flaky connection would each independently look like
    /// a "real" change and hop to `MainActor`, even though `MPNowPlayingInfoCenter` already
    /// extrapolates elapsed time from rate + a reference point on its own and doesn't need it
    /// re-sent every tick. The extrapolation check keeps that burst cheap while still publishing
    /// immediately on anything that's actually a discontinuity.
    ///
    /// This is the *only* function that writes to `MPNowPlayingInfoCenter` — `stop()` doesn't
    /// call a separate "clear" method. `teardownCurrentSession()` (called from both `stop()` and
    /// `load(_:)`) resets `currentMediaItem` to `nil` before `apply(_:)` runs, so the `nil`
    /// branch below is what "clear the lock screen" actually is: one more state this same
    /// dedup-guarded function reacts to, not a second, independently-racing writer.
    ///
    /// The `nil` branch can't use `lastPublishedRate`/`lastPublishedElapsedTime`/
    /// `lastPublishedDuration` to detect "was anything published" — `teardownCurrentSession()`
    /// already reset those to `nil` before `apply(_:)` runs, for *both* `stop()` and `load(_:)`.
    /// `isNowPlayingInfoPublished` tracks that independently. It also can't clear on every `nil`
    /// `currentMediaItem`: `load(_:)`'s own `apply(.loadRequested)` hits this same branch while
    /// `currentMediaItem` is transiently `nil` (before `load(_:)` sets it a few lines later) —
    /// clearing there would be undone a moment later anyway, the exact "wasted extra write"
    /// `load(_:)`'s teardown call was already designed to avoid. `.idle` (true only after
    /// `.stopRequested`, or before anything has ever loaded) and `.failed` (a `load(_:)` that
    /// didn't make it far enough to set `currentMediaItem` — an invalid URL or a session
    /// activation failure) are both "truly nothing loaded" states; `.loading` (from
    /// `.loadRequested`, momentarily, before `load(_:)` sets `currentMediaItem` a few lines
    /// later) is the one that must *not* trigger a clear here.
    ///
    /// `.failed` was originally left out of this check (a real bug, caught in review): a
    /// `load(_:)` call that failed before setting `currentMediaItem` would leave whatever was
    /// published for the *previous*, unrelated item frozen on the lock screen indefinitely —
    /// wrong metadata, wrong rate, with no indication anything failed, until the next successful
    /// `load(_:)` or an explicit `stop()`. A `.failed` reached *after* `currentMediaItem` was
    /// already set (e.g. a decode error mid-playback, not this branch at all — the non-`nil`
    /// branch below handles that case) is unaffected by this fix and correctly keeps showing
    /// that item's real metadata with `rate: 0.0`.
    ///
    /// A prior version had a separate `clearNowPlayingInfo()` awaited directly inside `stop()`,
    /// with no guard at all before writing — a `load(_:)` reentering the actor during that
    /// `await` could have its fresh publish land *before* the stale clear, wiping out valid info
    /// for the newly-loading item. Collapsing to one writer removes most of that risk, but the
    /// underlying hazard (two independent `Task`s racing to `MainActor`) still applies to this
    /// branch too — `clearNowPlayingInfo()` re-checks `currentMediaItem == nil` right before
    /// writing, so if a `load(_:)` lands in the meantime, this clear becomes a no-op instead of
    /// overwriting that load's own publish.
    private func refreshNowPlayingInfo() {
        guard let currentMediaItem else {
            let nothingIsLoaded: Bool
            switch stateMachine.state {
            case .idle, .failed:
                nothingIsLoaded = true
            case .loading, .buffering, .playing, .paused, .stalled, .ended:
                nothingIsLoaded = false
            }
            guard nothingIsLoaded, isNowPlayingInfoPublished else { return }
            isNowPlayingInfoPublished = false
            Task { [weak self] in
                await self?.clearNowPlayingInfo()
            }
            return
        }
        isNowPlayingInfoPublished = true

        let rate: Double = stateMachine.state == .playing ? 1.0 : 0.0
        let elapsed = currentTime
        let itemDuration = duration
        let now = Date()

        let rateChanged = rate != lastPublishedRate
        let durationChanged = itemDuration != lastPublishedDuration
        let elapsedIsDiscontinuous: Bool
        if let lastPublishedElapsedTime, let lastPublishedRate, let lastPublishTimestamp {
            let expectedElapsed = lastPublishedElapsedTime + lastPublishedRate * now.timeIntervalSince(lastPublishTimestamp)
            elapsedIsDiscontinuous = abs(elapsed - expectedElapsed) > Self.elapsedDiscontinuityThreshold
        } else {
            elapsedIsDiscontinuous = true // nothing published yet for this item
        }

        guard rateChanged || durationChanged || elapsedIsDiscontinuous else {
            return
        }
        lastPublishedRate = rate
        lastPublishedElapsedTime = elapsed
        lastPublishedDuration = itemDuration
        lastPublishTimestamp = now

        // Captured now, not read again after the `MainActor` hop below — `publishNowPlayingInfo`
        // re-checks `currentItem` against this snapshot before writing, which is what makes a
        // stale write (from a `load(_:)` that raced this one, per actor reentrancy at `await`
        // points) a no-op instead of overwriting a newer item's info.
        let expectedItem = currentItem
        let mediaItem = currentMediaItem
        Task { [weak self] in
            guard let self else { return }
            await self.publishNowPlayingInfo(
                mediaItem: mediaItem,
                rate: rate,
                elapsed: elapsed,
                itemDuration: itemDuration,
                expectedItem: expectedItem
            )
        }
    }

    /// Writes the full Now Playing dictionary to `MPNowPlayingInfoCenter`, hopped to `MainActor`
    /// (`concurrency-model.md` §8) since it's a UI-adjacent system singleton. Re-checks
    /// `currentItem` (actor-isolated, so safe to read here before the hop) against `expectedItem`
    /// first — see `refreshNowPlayingInfo()`'s doc comment for why this guard exists.
    ///
    /// Artwork is decoded here, on this actor's own executor, *before* the `MainActor` hop — not
    /// inside the `MainActor.run` closure, where it used to run. A real bug, caught in review:
    /// `PlatformImage(data:)` is a real, potentially expensive decode for a large embedded image,
    /// and running it on the main thread risked a visible UI hitch in the host app at exactly the
    /// moment least wanted (mid-scroll, mid-animation). Decoding off-main and handing the
    /// already-decoded image into the closure keeps the main-thread portion to just the
    /// dictionary write itself.
    private func publishNowPlayingInfo(
        mediaItem: MediaItem,
        rate: Double,
        elapsed: TimeInterval,
        itemDuration: TimeInterval?,
        expectedItem: AVPlayerItem?
    ) async {
        guard currentItem === expectedItem else { return }

        let artwork: MPMediaItemArtwork? = mediaItem.artworkData.flatMap { data in
            PlatformImage(data: data).map { image in
                // `requestedSize` is what the system actually wants this rendered at for the
                // context asking (e.g. a small lock-screen thumbnail vs. a full-screen Now
                // Playing view) — resizing to it, rather than always returning the original,
                // avoids handing back an oversized image the caller would just downscale itself.
                MPMediaItemArtwork(boundsSize: image.size) { requestedSize in
                    image.resized(to: requestedSize)
                }
            }
        }

        await MainActor.run {
            var info: [String: Any] = [
                MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
                MPNowPlayingInfoPropertyPlaybackRate: rate,
                MPNowPlayingInfoPropertyIsLiveStream: itemDuration == nil
            ]
            if let title = mediaItem.title {
                info[MPMediaItemPropertyTitle] = title
            }
            if let artist = mediaItem.artist {
                info[MPMediaItemPropertyArtist] = artist
            }
            if let itemDuration {
                info[MPMediaItemPropertyPlaybackDuration] = itemDuration
            }
            if let artwork {
                info[MPMediaItemPropertyArtwork] = artwork
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info

            // A stream with no known duration isn't seekable — don't offer a scrub control that
            // would always be a no-op (`seek(to:)`'s own `.idle`/`.loading`/`.failed` guard
            // doesn't cover this case, since an unknown-duration item can still be `.playing`).
            MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = itemDuration != nil
        }
    }

    /// Clears Now Playing info when playback fully stops, called only from `refreshNowPlayingInfo()`'s
    /// `nil`-`currentMediaItem`/`.idle` branch. Re-checks `currentMediaItem == nil` (actor-isolated,
    /// safe to read here before the hop) right before writing — the same reentrancy hazard
    /// `publishNowPlayingInfo` guards against applies here too: if a `load(_:)` reentered the
    /// actor and set `currentMediaItem` between this `Task` being spawned and now, this clear
    /// would otherwise wipe out that load's own (possibly already-written) info.
    private func clearNowPlayingInfo() async {
        guard currentMediaItem == nil else { return }
        await MainActor.run {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    /// Registers play/pause/seek handlers directly on `MPRemoteCommandCenter.shared()` so
    /// lock-screen/Control Center/headphones controls invoke the same `play()`/`pause()`/
    /// `seek(to:)` commands a direct caller would — no separate logic path. `MainActor`-hopped,
    /// same reasoning as `publishNowPlayingInfo`. Each handler captures `[weak self]` and hops
    /// back into this actor via its own `Task`, mirroring the KVO/NotificationCenter pattern in
    /// `startObserving(_:)` — a stale handler firing after `self` is deallocated is a harmless
    /// no-op rather than a crash. Called once, from `init`.
    ///
    /// `removeTarget(nil)` (removes *every* target for that command, not just ones registered
    /// by a specific object) runs before each `addTarget` — a real bug, caught in review: since
    /// `MPRemoteCommandCenter.shared()` is a single process-global object and there is no
    /// `deinit`-time cleanup an actor can run, every `PlaybackEngine` instance ever created over
    /// an app's lifetime (logout/login, account switching, a rebuilt player) would otherwise
    /// leave its own dead-but-still-registered closures behind forever, growing unbounded and
    /// each still firing (harmlessly, but wastefully) on every future remote command. Wiping
    /// first means at most one live target per command exists at any time regardless of how many
    /// instances have come and gone — and if two engines are ever briefly alive at once, this is
    /// also the correct behavior: only the most recently configured one should own the system's
    /// remote-command surface, matching how "Now Playing" ownership works system-wide.
    ///
    /// Registers directly against the real, process-global `MPRemoteCommandCenter.shared()` —
    /// deliberately no injectable seam here. This makes the wiring itself untestable via
    /// `swift test` (verified manually/by integration instead), traded for not carrying a
    /// protocol + fake whose only reason to exist would be testability, not the feature.
    private func configureRemoteCommands() async {
        await MainActor.run {
            let commandCenter = MPRemoteCommandCenter.shared()

            commandCenter.playCommand.removeTarget(nil)
            commandCenter.playCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { await self.play() }
                return .success
            }
            commandCenter.pauseCommand.removeTarget(nil)
            commandCenter.pauseCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { await self.pause() }
                return .success
            }
            commandCenter.changePlaybackPositionCommand.removeTarget(nil)
            commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }
                Task { await self.seek(to: event.positionTime) }
                return .success
            }
        }
    }
}

/// The three things `MediaSource.fetchWithRetry` can report, collapsed into one type so
/// `handleMediaSourceStallSignal(_:)` has a single funnel-in point rather than three separate
/// private functions — mirrors how `apply(_:)` is the one funnel-in point for state-machine
/// events.
enum MediaSourceSignal {
    case stallBegan
    case stallRecovered
    case retryBudgetExhausted(PlaybackError)
}

// MARK: - MediaSourceDelegate

extension PlaybackEngine: MediaSourceDelegate {
    func mediaSourceDidBeginStall() async {
        handleMediaSourceStallSignal(.stallBegan)
    }

    func mediaSourceDidRecoverFromStall() async {
        handleMediaSourceStallSignal(.stallRecovered)
    }

    func mediaSource(_ mediaSource: MediaSource, didExhaustRetryBudgetWith error: PlaybackError) async {
        handleMediaSourceStallSignal(.retryBudgetExhausted(error))
    }
}
