# AudioStreamKit V1 — High-Level Architecture

Status: Accepted (2026-09-11). Scope: see `v1-requirements.md`.

## Layering

Dependencies flow in one direction only:

```
AudioPlayer  (public facade, actor)
   |
   +--> PlaybackStateMachine   (pure logic, no I/O, no AVFoundation)
   |
   +--> PlaybackEngine         (the AVFoundation-facing layer)
            |
            +--> AVPlayer / AVPlayerItem   (Apple)
            |
            +--> MediaSource               (resource-loading seam)
                     |
                     +--> MediaCache        (actor, on-disk byte cache)
                     |
                     +--> URLSession  -->  RetryPolicy
```

`MediaCache` and `MediaSource` do not know `PlaybackEngine` exists;
`PlaybackEngine` does not know `AudioPlayer` exists. This is deliberate: it
lets each layer be tested in isolation, and each layer maps to one of the
test categories (state transitions, cache
behavior, retry behavior, cancellation).

## Component Responsibilities

- **`AudioPlayer`** (public facade) — the only type most consumers touch:
  `load(url:)`, `play()`, `pause()`, `stop()`, `seek(to:)`, an async state
  stream, `currentTime`/`duration`. Owns exactly one active playback
  session (single-item scope; see `v1-requirements.md` non-goals).
- **`PlaybackStateMachine`** — pure state logic. Takes events in
  (`.readyToPlay`, `.stalled`, `.interruptionBegan`,
  `.interruptionEnded(shouldResume:)`, `.failed(Error)`), produces state
  out (idle/loading/buffering/playing/paused/stalled/failed/ended), rejects
  illegal transitions. No I/O — fully unit-testable without AVFoundation.
- **`PlaybackEngine`** — wraps `AVPlayer`/`AVPlayerItem`. Translates their
  KVO/NotificationCenter lifecycle into events fed to the state machine.
  Owns `AVAudioSession` setup, interruption/route-change handling,
  `MPRemoteCommandCenter`/`MPNowPlayingInfoCenter` wiring.
- **`MediaSource`** — the resource-loading seam between `AVPlayer` and the
  network/cache. See `streaming-and-caching.md` and `ADR-001` for why this
  intercepts requests rather than letting `AVPlayer` stream directly.
- **`MediaCache`** — actor. On-disk store keyed by URL, byte-range aware,
  LRU-bounded, ETag/Last-Modified validated. Pure data management — "what
  do you have for this range" / "here's a range I fetched, store it."
- **`RetryPolicy`** — small, focused exponential-backoff logic for
  recoverable network failures during streaming. See `ADR-002` for why
  this is hand-rolled rather than a SwiftResilience dependency.

## Concurrency Model (overview)

Stateful components (`AudioPlayer`, `PlaybackEngine`, `MediaCache`) are
actors. AVFoundation callbacks arrive on arbitrary system queues — the
engine hops into actor context immediately at that boundary. Consumer-
facing state is exposed as an `AsyncStream`, not delegate callbacks, so
tests can `await` state changes directly. A full concurrency-model deep
dive (isolation boundaries, `Sendable` requirements) is a separate,
later topic.

## Module Structure

Single SPM target (`AudioStreamKit`) for V1, organized internally by
folder (`Playback/`, `Cache/`, `Networking/`, `State/`, `PublicAPI/`)
rather than split into multiple SPM targets. Splitting now would be
premature; revisit if/when the download/offline milestone adds enough
surface to justify it.

## Public API Philosophy

Only `AudioPlayer` + its state/error types + minimal cache configuration
are public. `PlaybackStateMachine`, `PlaybackEngine`, `MediaCache`, and
`MediaSource` are internal. This keeps NFR12 (small, stable API) real: we
can change any internal subsystem without breaking consumers.

## Related Documents

- `v1-requirements.md` — the requirements this architecture satisfies.
- `streaming-and-caching.md` — detailed design of `MediaSource`/`MediaCache`.
- `../decisions/ADR-001-resource-loading-strategy.md`
- `../decisions/ADR-002-retry-policy-dependency.md`
