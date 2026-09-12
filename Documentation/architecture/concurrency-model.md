# AudioStreamKit V1 — Concurrency Model

Status: Proposed (2026-09-11) — drafted, not yet discussed/confirmed.
Detail behind the "Concurrency Model (overview)" section in
`high-level-architecture.md`. Satisfies NFR6, NFR7, NFR10, NFR11.

## 1. Ground rule: Swift 6 language mode

`Package.swift` targets `swift-tools-version: 6.0` with no override, which
already defaults both targets to Swift 6 language mode (full data-race
safety checking). This doc makes that explicit in `Package.swift` rather
than leaving it implicit, since every rule below is meant to be
compiler-enforced, not convention-enforced — a `Sendable` violation or a
cross-actor access should fail to build, not fail in a race detector at
runtime.

## 2. Isolation map

| Type | Isolation | Why |
|---|---|---|
| `AudioPlayer` | `actor` | Public facade; NFR6 requires shared mutable state to be actor-isolated. |
| `PlaybackEngine` | `actor` | Owns `AVPlayer`/session/remote-command state. |
| `MediaCache` | `actor` | Already decided (`streaming-and-caching.md` §9). |
| `PlaybackStateMachine` | plain type, no isolation | Pure logic (§1 of `playback-state-machine.md`), single-threaded by construction — its only caller, `PlaybackEngine`, is already an actor, so every call into it is already serialized. Making it an actor too would be redundant isolation for no safety benefit. |
| `RetryPolicy` | plain `Sendable` struct | Stateless — computes a backoff delay from an attempt count. No shared mutable state, so no isolation needed at all; safely callable from anywhere. |
| `MediaSource` | `NSObject` class, **not** an actor | See §3 — forced by `AVAssetResourceLoaderDelegate`'s `NSObjectProtocol` requirement, which a Swift `actor` cannot satisfy. |

## 3. `MediaSource`: the NSObject/actor interop problem

This is the one place the "everything stateful is an actor" rule from
`high-level-architecture.md` can't literally apply, and it's worth being
explicit about why, rather than quietly working around it.

`AVAssetResourceLoaderDelegate` requires conformance to `NSObjectProtocol`
— the delegate must be a real Objective-C-compatible class. Swift actors
cannot subclass `NSObject`. So `MediaSource` must be a plain `NSObject`
subclass, and its delegate methods
(`resourceLoader(_:shouldWaitForLoadingOfRequestedResource:)`,
`resourceLoader(_:didCancel:)`) are synchronous, non-`async` callback
methods — AVFoundation calls them and expects a quick, non-blocking
return, with the actual work continuing asynchronously until
`loadingRequest.finishLoading(...)`/`respond(with:)` is eventually called
(documented as safe to call from any queue).

`MediaSource` still has real mutable state that needs protecting: the
per-`AVAssetResourceLoadingRequest` tracked-`Task` bookkeeping from
`streaming-and-caching.md` §5 (needed so `didCancel` can cancel exactly
the right in-flight work). Two ingredients, used together:

- **A dedicated serial `DispatchQueue`** is assigned as the resource
  loader's delegate queue (`asset.resourceLoader.setDelegate(mediaSource,
  queue: dedicatedQueue)`). This guarantees AVFoundation itself never
  calls two delegate methods on `MediaSource` concurrently — without
  this, passing `nil` lets AVFoundation pick an arbitrary/concurrent
  queue, which would make even *entering* the delegate methods a race.
- **A nested Swift `actor`** (private, not `MediaSource` itself) owns the
  loadingRequest → Task dictionary. Each synchronous delegate method body
  does the minimum synchronous work needed, then `Task { await
  tracker.register(...) }` (or `.cancel(...)`) to mutate that state — real
  actor isolation for the state that actually needs it, without requiring
  `MediaSource` itself to be an actor.

The serial delegate queue and the nested actor are solving two different
problems: the queue controls *when AVFoundation is allowed to call in*;
the actor controls *safe mutation of MediaSource's own bookkeeping*. Both
are needed — the queue alone doesn't help once work escapes into a
detached `Task`, and the actor alone doesn't stop AVFoundation from
entering the delegate methods concurrently in the first place.

## 4. State propagation without polling (NFR10)

`AudioPlayer` owns the `AsyncStream<PlaybackState>` and its
`Continuation`. Rather than `PlaybackEngine` exposing its own second
stream that `AudioPlayer` forwards (a stream-of-a-stream, with its own
forwarding `Task` to manage and cancel), `AudioPlayer` passes the
`Continuation` directly into `PlaybackEngine` at construction:

```swift
actor AudioPlayer {
    let states: AsyncStream<PlaybackState>

    init(cacheConfiguration: CacheConfiguration = .default) {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        self.states = AsyncStream { continuation = $0 }
        self.engine = PlaybackEngine(stateSink: continuation)
    }
}
```

`AsyncStream.Continuation.yield(_:)` is documented safe to call from any
thread/actor, so `PlaybackEngine` calls it directly after every
`PlaybackStateMachine` transition — no forwarding loop, no extra `Task`,
and no polling on `AudioPlayer`'s side to notice a change.

## 5. `MediaCache` off-actor reads

Already decided in `streaming-and-caching.md` §9: `MediaCache` hands back
a safe read plan (offset + file handle) so the actual disk read for a
cache hit can happen off-actor, since disjoint reads on a sparse file
don't need to serialize through the actor.

One sharp edge this doc adds: disjoint concurrent reads are only actually
safe if they don't share mutable read-position state. A `seek()`-then-
`read()` pattern on a single shared file handle *is* a race if two
concurrent reads use the same handle — the fix is that each read must be
position-explicit (an offset-based read, not "seek the shared cursor,
then read") or use its own independent handle per read, so two concurrent
reads at different offsets genuinely can't interfere with each other.
This is a concrete implementation constraint to get right when
`MediaCache`'s "read plan" is actually implemented, not just a place
where "off-actor" alone is sufficient.

## 6. Cancellation (NFR7)

Structured concurrency's automatic cancellation propagation (a parent
`Task`'s cancellation cancelling its `await`ed children) does **not**
apply to most of the work in this framework, and it's worth being
explicit about why: the work that needs cancelling — an in-flight
byte-range fetch inside `MediaSource`, a retry loop in `RetryPolicy` —
must outlive the `AudioPlayer` method call that started it (e.g.
`play()` returns quickly; the network fetch it kicked off keeps running
after `play()` has already returned). That means these are necessarily
independent, unstructured `Task`s, not structured children of the
caller's `Task` — so cancelling the caller's own `Task` (e.g. a SwiftUI
`Task { await player.stop() }` being cancelled) does **not**
automatically cancel them.

Given that, cancellation is explicit and event-driven, not automatic:

- `.stopRequested` and `.loadRequested` (global rules,
  `playback-state-machine.md` §4) are the trigger points. When either
  fires, `PlaybackEngine` tells `MediaSource` to cancel everything
  tracked for the current item; `MediaSource`'s nested tracker actor
  calls `.cancel()` on every tracked `Task` and clears its dictionary.
- `resourceLoader(_:didCancel:)` (AVFoundation cancelling one specific
  loading request, e.g. superseded by a seek) cancels only that request's
  tracked `Task`, per `streaming-and-caching.md` §5 — already decided,
  restated here because it's the same tracked-`Task` mechanism.
- Every tracked `Task`'s body must itself check `Task.isCancelled` (or
  rely on `Task.checkCancellation()` inside `URLSession`
  async-await calls, which throw `CancellationError` on cancellation) so
  cancelling the `Task` handle actually stops in-flight work rather than
  just detaching from it.

## 7. `Sendable` inventory

Every type that crosses an actor boundary must be `Sendable` — this is
the concrete, compiler-checked form of NFR6/NFR11 under Swift 6 mode.

| Type | Sendable? | Notes |
|---|---|---|
| `PlaybackState` | Yes | Enum of value types + `PlaybackError`. |
| `PlaybackEvent` | Yes | Enum of value types + `PlaybackError`. |
| `PlaybackError` | Yes | Already marked in `public-api.md` §6. |
| `MediaItem` | Yes | Already marked in `public-api.md` §4. |
| `CacheConfiguration` | Yes | Already marked in `public-api.md` §5. |
| Cache metadata record (`streaming-and-caching.md` §2) | Yes, must be | Returned from `MediaCache` actor calls — needs an explicit `Sendable` struct, not yet named as a public/internal type in that doc; naming it is a small follow-up when `MediaCache` is actually implemented. |
| `AsyncStream<PlaybackState>.Continuation` | Yes (Foundation-provided) | Passed into `PlaybackEngine` at init (§4). |
| File handle used for cache reads | Must be treated as **not** safely shared without the offset-explicit-read discipline in §5 | Not a blanket `Sendable` win — see §5's caveat. |

## 8. `MainActor` usage — narrow, not framework-wide

`AudioPlayer` and `PlaybackEngine` are their own actors, not `MainActor`
— nothing about playback logic needs the main thread. The one exception:
`MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` calls (FR6) are hopped to
`MainActor` explicitly at the call site inside `PlaybackEngine` (`await
MainActor.run { ... }` or an `@MainActor`-isolated private method), since
these are UI-adjacent system singletons Apple's own sample code
consistently touches from the main thread. This is a narrow,
call-site-scoped exception, not a reason to make any framework type
`@MainActor`-isolated.

## 9. Open questions

- The `MediaSource` nested tracker actor's exact API (register/cancel/
  cancelAll) isn't specified here — that's implementation detail once
  `MediaSource` is actually written, not a concurrency-model decision.
- Whether `RetryPolicy`'s backoff computation should be exposed as a pure
  function vs. a struct with configuration (max attempts, base delay) is
  implementation detail, not a concurrency question — deferred.

## 10. Related Documents

- `high-level-architecture.md` — layering and the original concurrency
  overview this doc details.
- `streaming-and-caching.md` §5, §9 — cancellation and `MediaCache`
  actor-isolation decisions this doc builds on rather than repeats.
- `playback-state-machine.md` §1, §4 — why `PlaybackStateMachine` needs
  no isolation of its own, and the global cancellation trigger events.
- `public-api.md` §6 — `PlaybackError`'s `Sendable` conformance.
