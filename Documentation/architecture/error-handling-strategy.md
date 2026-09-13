# AudioStreamKit V1 — Error Handling Strategy

Status: Accepted (2026-09-13).

Finalizes the `PlaybackError` sketch in `public-api.md` §6 and the retry
integration referenced in `streaming-and-caching.md` §6. Satisfies FR10,
FR11, FR12, NFR8.

## 1. Goal

Two things were deliberately left open elsewhere:

- `public-api.md` §6: `PlaybackError` is a placeholder shape, not a
  finalized taxonomy.
- `streaming-and-caching.md` §6: "a transient failure ... goes through
  `RetryPolicy`" without saying which failures count as transient, or
  what "exhausted" maps to on the public side.

This doc closes both gaps: a finalized `PlaybackError`, and the
classification rules that decide, for any raw failure, whether it's
retried (Tier 1, invisible to the caller) or surfaced (Tier 2, a public
`PlaybackError`).

## 2. Two-tier model

**Tier 1 — transient, internal.** A single byte-range fetch failing
inside `MediaSource`. Classified *before* `RetryPolicy` engages — the
classification decides whether to retry at all, not just when to stop
retrying. While retries are in flight, this is the `.stalled` state
(`playback-state-machine.md` §2) — not an error, not visible as one.

**Tier 2 — terminal, public.** A `PlaybackError` reaches
`.failed(PlaybackError)` one of two ways:

- A Tier-1 failure that was classified retryable exhausts its retry
  budget (`.retryBudgetExhausted(PlaybackError)`, already an event in
  `playback-state-machine.md` §3).
- A failure that's terminal on first sight — never enters Tier 1 at all
  (e.g. a 404, a corrupt file). Reported directly as `.itemFailed(PlaybackError)`.

The classification step is what decides which path a given raw failure
takes. It lives as a pure function (see §5) so it's unit-testable per
NFR11 without a real network — table of inputs to expected tier, no
`URLSession` involved.

## 3. `PlaybackError` (finalized)

```swift
public enum PlaybackError: Error, Sendable, Equatable {
    case invalidURL
    case network(URLError)
    case http(statusCode: Int)
    case decodeFailed
    case unsupportedFormat
    case cancelled
}
```

Changes from the `public-api.md` §6 sketch:

- **Dropped `unknown(underlying: Error)`.** `Error` isn't `Equatable`,
  which would force a hand-rolled `==` that always returns `false` for
  that case (or ignores the payload) — either defeats the point of
  `Equatable` for tests that assert "the player failed with X". Every
  raw failure this framework can actually encounter (`URLError`, HTTP
  status, AVFoundation decode/format errors, a bad URL) has a concrete
  case below. If AVFoundation ever surfaces something genuinely
  unclassifiable, that's a bug in the classifier (§5) to fix, not a case
  for callers to pattern-match defensively around.
- **Added `.cancelled`.** Needed so a caller-visible failure path exists
  for "the loading request was cancelled and nothing else is coming" —
  distinct from a stall or a real terminal error. In practice this
  should rarely reach `.failed`: `.stopRequested`/`.loadRequested`
  already tear down cleanly via the state machine's global rules
  (`playback-state-machine.md` §4) without routing through `.failed` at
  all. It exists for the edge case of a cancellation that races with
  a not-yet-superseded loading request reporting failure before the
  engine's teardown event lands — kept here rather than silently
  swallowed, per AGENTS.md ("do not hide failures").

### `LocalizedError` conformance

```swift
extension PlaybackError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The media URL is invalid."
        case .network(let urlError): urlError.localizedDescription
        case .http(let statusCode): "Server returned an error (\(statusCode))."
        case .decodeFailed: "The media could not be decoded."
        case .unsupportedFormat: "This media format isn't supported."
        case .cancelled: "Playback was cancelled."
        }
    }
}
```

Not exhaustive/final copy — the point being decided here is *that*
`PlaybackError` conforms to `LocalizedError` at all (so a consumer can
show `error.localizedDescription` directly in UI without a
caller-side `switch`), not the exact wording.

## 4. Classification rules

### Network layer (`URLError`)

| `URLError.Code` | Tier | Maps to |
|---|---|---|
| `.timedOut`, `.networkConnectionLost`, `.cannotConnectToHost`, `.notConnectedToInternet`, `.dnsLookupFailed`, `.cannotFindHost` | 1 (retryable) | on exhaustion: `.network(urlError)` |
| `.badURL`, `.unsupportedURL` | 2 (terminal, immediate) | `.invalidURL` |
| anything else | 2 (terminal, immediate) | `.network(urlError)` |

Rationale for the "anything else → terminal" default: an unrecognized
`URLError` code is more likely a real, non-transient problem than a
blip worth retrying — defaulting to retry-everything risks masking a
real failure behind repeated backoff delays, which works against NFR8
("before surfacing a terminal error", not "instead of").

### HTTP layer (response received, non-2xx)

| Status | Tier | Maps to |
|---|---|---|
| 408, 429, 500–599 | 1 (retryable) | on exhaustion: `.http(statusCode:)` |
| all other 4xx (400, 401, 403, 404, 410, ...) | 2 (terminal, immediate) | `.http(statusCode:)` |

429/408 are retryable because they're explicitly transient-by-design in
HTTP semantics (rate limiting / request timeout); other 4xx codes mean
the request itself is wrong and won't succeed on retry (bad URL, 403,
gone), so retrying just burns the backoff budget for nothing.

### Asset layer (AVFoundation)

| Failure | Tier | Maps to |
|---|---|---|
| Asset fails to load / parse (`AVURLAsset` load error, non-network) | 2 (terminal, immediate) | `.decodeFailed` |
| Asset loads but format/codec unsupported for playback | 2 (terminal, immediate) | `.unsupportedFormat` |

Always terminal — retrying doesn't fix a corrupt file or an unsupported
codec, so routing these through `RetryPolicy` would only add delay
before a failure that was already certain.

### Cache layer — not a `PlaybackError` at all

A `MediaCache` write failure (disk full, permission error) does **not**
produce a `PlaybackError` and does **not** affect the state machine.
Caching degrades to best-effort: the in-flight `dataRequest` is still
satisfied from the network bytes already in hand
(`streaming-and-caching.md` §4), the write-through to disk is simply
skipped for that range, and playback continues. A caching-layer problem
failing an otherwise-healthy stream would contradict FR17 ("plays with
no network" is a *benefit* of caching, not a dependency of playback).
This is a deliberate asymmetry with the network/HTTP/asset layers above,
worth stating explicitly rather than leaving implicit.

## 5. Where classification lives

A pure function, colocated with `RetryPolicy` (same "no I/O, injectable,
unit-testable per NFR11" shape as `PlaybackStateMachine`):

```swift
enum FailureClassification: Equatable {
    case retry
    case terminal(PlaybackError)
}

func classify(_ error: Error) -> FailureClassification
```

`MediaSource` calls this on every byte-range fetch failure. `.retry`
hands the failure to `RetryPolicy` for backoff scheduling (Tier 1,
`.stalled`); `.terminal(error)` reports `.itemFailed(error)` immediately,
bypassing `RetryPolicy` entirely. On retry-budget exhaustion,
`RetryPolicy` re-classifies the *last* underlying error the same way to
produce the `PlaybackError` payload for `.retryBudgetExhausted(error)` —
same function, no separate exhaustion-specific mapping to keep in sync.

## 6. Retry budget scope — accepted (2026-09-13)

**Item-scoped, not range-scoped.** A single rolling
attempt/failure count tracked per loaded item (reset on `.loadRequested`
and on any successful range fetch), not a fresh budget for every new
byte-range request.

Why this matters: if the budget reset per range, a connection that fails
every *new* range but always succeeds on *retry* of that same range
could retry forever without ever exhausting — each individual range
"succeeds eventually," so no single range ever hits its own budget, but
the item is effectively unplayable. Item-scoping (reset only on genuine
forward progress — a successful fetch) is what actually satisfies NFR8's
"before surfacing a terminal error," since it guarantees eventual
termination for a truly bad connection regardless of how failures are
distributed across ranges.

**This was flagged rather than silently decided, because it changes
observable behavior**: a brief real-world flaky patch (several different
ranges each failing once, each succeeding on their own first retry)
consumes shared budget under item-scoping but not under range-scoping.
Confirmed 2026-09-13: item-scoped.

## 7. Open questions

- Exact backoff parameters (base delay, max attempts, jitter) for
  `RetryPolicy` — implementation detail, deferred per
  `concurrency-model.md` §9 (already flagged there as out of scope for
  the concurrency doc; restated here as out of scope for this doc too).
- `LocalizedError` copy in §3 is illustrative, not final wording.
- Whether `.cancelled` should be reachable in practice at all, or turns
  out to be dead code once `PlaybackEngine`'s teardown ordering is fully
  implemented — kept for now per AGENTS.md ("do not hide failures"),
  revisit once real cancellation races can be tested (NFR7).

## 8. Related Documents

- `public-api.md` §6 — the `PlaybackError` sketch this doc finalizes.
- `playback-state-machine.md` §2–3 — `.stalled` vs `.failed`, and the
  `.itemFailed`/`.retryBudgetExhausted` events this doc's classifier
  feeds.
- `streaming-and-caching.md` §6–8 — retry integration and cache
  validation/eviction this doc's cache-layer rule (§4) builds on.
- `v1-requirements.md` — FR10, FR11, FR12, NFR8.
