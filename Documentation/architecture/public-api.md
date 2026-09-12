# AudioStreamKit V1 — Public API Design

Status: Accepted (2026-09-11).
Detail behind the "Public API Philosophy" section and `AudioPlayer` box in
`high-level-architecture.md`. Satisfies FR1-FR13, FR6 specifically, NFR12.

## 1. Goal

NFR12: "a playback controller + cache configuration. Internal subsystems
aren't public unless a consumer genuinely needs them." This doc makes that
concrete — enumerates the actual public symbols, and for each one, states
why it's public rather than assuming the answer is obvious.

Everything not listed in §2 stays `internal`: `PlaybackStateMachine`,
`PlaybackEngine`, `MediaSource`, `MediaCache`, `RetryPolicy`.

## 2. Public symbol inventory

| Symbol | Kind | Why public |
|---|---|---|
| `AudioPlayer` | actor | The facade — see §3. |
| `PlaybackState` | enum | FR4 requires exposing state; the *type* is public even though the engine that drives it (`PlaybackStateMachine`) is not. Already designed in `playback-state-machine.md`. |
| `PlaybackError` | enum | FR12 requires typed, actionable errors. Full taxonomy is a separate open topic (error-handling strategy) — sketched, not finalized, here. |
| `MediaItem` | struct | What you hand `load()` — see §4. |
| `CacheConfiguration` | struct | What you hand `AudioPlayer.init` — see §5. |

Five public symbols total, one of which (`AudioPlayer`) is the only thing
most consumers interact with directly.

## 3. `AudioPlayer`

```swift
public actor AudioPlayer {
    public init(cacheConfiguration: CacheConfiguration = .default)

    public func load(_ item: MediaItem) async
    public func play() async
    public func pause() async
    public func stop() async
    public func seek(to time: TimeInterval) async

    public nonisolated let states: AsyncStream<PlaybackState>

    public var currentTime: TimeInterval { get async }
    public var duration: TimeInterval? { get async }   // nil until known
}
```

Notes on shape, each a deliberate choice:

- **`actor`**, not a class with manual locking. Matches NFR6 directly;
  every public method is automatically serialized.
- **`load(_:)` takes `MediaItem`, not a bare `URL`.** See §4 — this is the
  one place this doc extends past what `v1-requirements.md` literally
  specifies, to make FR6 (Now Playing info) actually implementable. Per
  your decision: caller supplies metadata, no embedded-tag parsing in V1.
- **No throwing methods.** `load`/`play`/`pause`/`stop`/`seek` don't
  `throws` — a bad URL, a 404, a decode failure, etc. all surface through
  `states` as `.failed(PlaybackError)` (already the state machine's
  design), not as a caught exception at the call site. This keeps error
  handling in one place (the state stream) instead of two (thrown errors
  *and* the state stream), which the state machine design already
  assumes (`.itemFailed`/`.retryBudgetExhausted` are just events, not
  something a caller `try/catch`es around a `play()` call).
- **`seek(to:)` takes `TimeInterval` (`Double`, seconds), not `CMTime`.**
  No AVFoundation types appear in the public API — this is what keeps
  `PlaybackEngine` free to change its AVFoundation usage without breaking
  callers, and keeps the public surface approachable to someone who's
  never touched AVFoundation.
- **`states: AsyncStream<PlaybackState>`**, `nonisolated let` — already
  decided in `high-level-architecture.md` ("exposed as an AsyncStream,
  not delegate callbacks, so tests can `await` state changes directly").
  A stored `nonisolated let` backed by a continuation captured at `init`
  is the standard actor + `AsyncStream` pattern; it lets a consumer
  `for await state in player.states` without hopping onto the actor for
  every iteration.
- **`currentTime`/`duration` are pull, not push.** FR5 only requires
  *exposing* position/duration, not streaming live updates. A UI that
  wants a moving progress bar can poll these cheaply at its own cadence
  (e.g. a SwiftUI `TimelineView`) — AudioStreamKit doesn't need to own
  that cadence decision. Reading `AVPlayer.currentTime()`/`.duration`
  under the hood is not the kind of "polling" NFR10 is about (there's no
  observation-based alternative for continuous position in AVFoundation
  itself); NFR10 is about not polling for *discrete* state changes that
  KVO/notifications already report, which `states` already handles.
  A dedicated live-position `AsyncStream<TimeInterval>` is listed as an
  open question (§7) rather than committed — it would be a second thing
  to keep in sync and a second thing to test, for a need FR5 doesn't
  actually ask for.

## 4. `MediaItem`

```swift
public struct MediaItem: Sendable, Equatable {
    public let url: URL
    public let title: String?
    public let artist: String?
    public let artworkData: Data?

    public init(url: URL, title: String? = nil, artist: String? = nil, artworkData: Data? = nil)
}
```

- All metadata fields are optional so `MediaItem(url: someURL)` still
  works for a quick test/demo — Now Playing then just shows less (no
  title/artist row, no artwork), it never fails to play over missing
  metadata.
- `artworkData: Data?` rather than `URL?` — `MPNowPlayingInfoCenter`
  wants an `MPMediaItemArtwork` built from an in-memory image; fetching
  artwork from a remote URL is a separate concern (a second network
  fetch, its own failure/caching story) that FR6 doesn't ask
  AudioStreamKit to own. If remote artwork is wanted later, the caller
  fetches it and passes `Data`, or that becomes its own explicit feature.

## 5. `CacheConfiguration`

```swift
public struct CacheConfiguration: Sendable, Equatable {
    public let maxSizeBytes: Int

    public init(maxSizeBytes: Int)

    public static let `default` = CacheConfiguration(maxSizeBytes: 200 * 1024 * 1024) // 200 MB
}
```

Minimal on purpose — FR15/NFR4 only require a size-bounded LRU cache to
exist and be configurable in size. Validation policy (§7 of
`streaming-and-caching.md`) and eviction mechanics stay internal; nothing
about *how* eviction works needs to be a caller's decision in V1.

## 6. `PlaybackError` (sketch only)

```swift
public enum PlaybackError: Error, Sendable {
    case invalidURL
    case network(URLError)
    case http(statusCode: Int)
    case decodeFailed
    case unsupportedFormat
    case unknown(underlying: Error)
}
```

This is a placeholder shape to unblock `PlaybackState.failed(PlaybackError)`
and this doc's method signatures — it is **not** the finalized taxonomy.
Error-handling strategy (retry classification, which of these are ever
retryable vs. always terminal, `LocalizedError` conformance for UI
display) is still an open planning topic.

## 7. Open questions

- Live-position `AsyncStream<TimeInterval>` in addition to pull-based
  `currentTime` — not committed; FR5 doesn't require it, would add public
  surface and an internal periodic-time-observer subsystem. Revisit if a
  consumer building a scrubber UI finds polling awkward.
- Should `AudioPlayer` be exposed only as a concrete `actor`, or also as
  a `protocol` for consumers who want to mock playback in their own
  tests? Leaning no for V1 — a protocol doubles the public surface
  (NFR12) for a need no FR asks for; revisit if requested.
- No module-prefixed symbol names (e.g. not `ASKPlayer`) — relying on
  Swift's module-qualification (`AudioStreamKit.AudioPlayer`) for
  collision avoidance, matching Apple's own framework conventions.

## 8. Related Documents

- `v1-requirements.md` — FR1-FR13, NFR12.
- `high-level-architecture.md` — Public API Philosophy, layering.
- `playback-state-machine.md` — `PlaybackState`, the type this API exposes.
