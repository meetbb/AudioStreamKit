# ADR-001: Resource Loading Strategy for Streaming Playback

## Status

Accepted (2026-09-11)

## Context

AudioStreamKit needs AVPlayer to play remote audio while satisfying FR14
(cache exactly the bytes actually read during playback), FR16 (cache
validation), FR10 (fine-grained retry on network failure during streaming),
and FR17 (a fully-cached item plays with no network). The question is how
bytes actually get from the network to AVPlayer, and how that connects to
AudioStreamKit's own on-disk cache.

## Decision

AudioStreamKit intercepts resource loading via a custom
`AVAssetResourceLoaderDelegate`. AudioStreamKit issues the actual HTTP
byte-range requests itself (via `URLSession`), feeds AVPlayer through the
loading request's `dataRequest`/`contentInformationRequest`, and caches at
exact byte-range granularity as bytes are fetched. See
`../architecture/streaming-and-caching.md` for the detailed design.

## Alternatives Considered

**Direct URL playback + background whole-file caching.** Let `AVPlayer`
stream directly from the remote URL, with AVFoundation handling all
networking opaquely. Caching becomes a separate background whole-file
download that, once complete, causes future plays of that URL to construct
the `AVPlayerItem` from the local file instead of the remote URL.

## Rationale

The chosen approach is the only one that satisfies FR14 and FR16 as
literally specified — caching exactly what was read, including partial
plays, and validating at that granularity. It also gives AudioStreamKit
its own retry control at the byte-range level (FR10), rather than
depending on whatever AVPlayer surfaces opaquely through KVO/stall
notifications. It is also the pattern used by production streaming
players that need this level of cache precision, and was chosen
deliberately over the simpler alternative for that reason.

## Trade-offs

- Advantages: exact byte-range caching; explicit retry control; no
  duplicated network transfer between "what's playing" and "what's being
  cached."
- Disadvantages: significantly higher implementation complexity and
  correctness risk than the alternative — resource-loader delegate
  callbacks fire on an internal queue, in-flight requests must be
  cancelled and cleaned up correctly on seek, and
  `contentInformationRequest` must be populated correctly (including
  `isByteRangeAccessSupported = true`) before any `dataRequest` can be
  answered. Getting any of this wrong causes silent, hard-to-diagnose
  playback or caching failures rather than a clean error.

The alternative (direct URL playback + background whole-file caching) is
substantially simpler and lower-risk, and still satisfies FR17 cleanly,
but only weakly satisfies FR14 (no caching of partial plays) and FR10
(retry limited to what AVPlayer itself surfaces).

## Consequences

- `MediaSource` becomes a real subsystem with its own concurrency and
  cancellation correctness requirements, not a thin pass-through.
- Test coverage must specifically exercise: concurrent overlapping loading
  requests, cancellation on seek, and correct `contentInformationRequest`
  population — these are exactly the failure modes this approach is prone
  to.
- If this proves too complex to get right within a reasonable timeframe,
  the fallback alternative documented above is a legitimate downgrade path
  and would be recorded as a new ADR superseding this one, not a silent
  change.

## References

- `../architecture/v1-requirements.md` (FR10, FR14, FR16, FR17)
- `../architecture/streaming-and-caching.md`
