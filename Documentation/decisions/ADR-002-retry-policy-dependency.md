# ADR-002: Retry Policy Implementation — Hand-Rolled vs. SwiftResilience

## Status

Accepted (2026-09-11)

## Context

Streaming playback needs bounded exponential-backoff retry for transient
network failures on individual byte-range fetches (FR10, NFR8). The user
already maintains a separate framework, SwiftResilience
(github.com/meetbb/SwiftResilience), which includes an
`ExponentialRetryPolicy` as part of its request-orchestration layers. The
question is whether AudioStreamKit should depend on SwiftResilience for
this, or implement its own retry policy.

## Decision

AudioStreamKit implements its own small, local `RetryPolicy` rather than
depending on SwiftResilience.

## Alternatives Considered

Depend on SwiftResilience and reuse its `ExponentialRetryPolicy` type
directly, for consistency across the user's projects.

## Rationale

SwiftResilience's retry policy is designed for its own layered
request-orchestration model, built around discrete `NetworkRequest` /
`NetworkError` request-response pairs (see
`../architecture/v1-requirements.md`, Networking Dependency Boundary
section). AudioStreamKit's retry need is a different shape of problem:
retrying a single missing byte sub-range within an in-flight
`AVAssetResourceLoadingRequest`, not retrying a discrete API call. Taking
SwiftResilience as a dependency for one backoff formula would couple
AudioStreamKit's core streaming loop to an external package whose
abstractions don't actually match this use case, contrary to the
Dependency Policy in `AGENTS.md` ("any new external dependency requires
justification").

## Trade-offs

- Advantages: no coupling to an external package for internal streaming
  logic; the policy can be shaped exactly to this use case (per-range
  retry, not per-request); zero risk of SwiftResilience's own evolution
  affecting AudioStreamKit's core loop.
- Disadvantages: minor duplication of a well-understood backoff formula
  across the user's two projects; no shared metrics/observability format
  between the two frameworks unless deliberately aligned later.

## Consequences

- AudioStreamKit takes no dependency on SwiftResilience for V1's core
  streaming path.
- If AudioStreamKit later needs discrete API calls (e.g. resolving a
  stream manifest URL), that is a separate integration point where
  SwiftResilience remains the right tool — this decision is scoped only to
  the byte-range retry logic inside `MediaSource`.

## References

- `../architecture/v1-requirements.md` (FR10, NFR8, Networking Dependency
  Boundary)
- `../architecture/streaming-and-caching.md` (section 6, Retry integration)
