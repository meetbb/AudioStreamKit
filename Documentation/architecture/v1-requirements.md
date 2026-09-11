# AudioStreamKit V1 Requirements

Status: Accepted (2026-09-11)

## Scope

V1 = reliable streaming playback of a single remote audio item, with basic
on-disk caching. Download/offline management is explicitly out of scope for
V1 and is deferred to a later milestone.

## Functional Requirements

### Core playback

- FR1 — Play a single audio item from a remote HTTP(S) URL. Progressive
  download only (MP3/AAC/M4A); HLS/adaptive streaming is explicitly deferred
  (see Non-Goals).
- FR2 — Pause / resume / stop.
- FR3 — Seek within the current item, where the server supports range
  requests.
- FR4 — Expose playback state (idle → loading → buffering → playing →
  paused → stalled → failed → ended) via an observable/async API, with only
  legal transitions allowed.
- FR5 — Expose current position and duration.
- FR6 — Integrate with system playback controls (lock screen / Control
  Center via `MPRemoteCommandCenter`) and Now Playing info
  (`MPNowPlayingInfoCenter`).
- FR7 — Continue playing when the app is backgrounded.
- FR8 — Handle audio session interruptions (phone call, Siri, another app
  taking audio focus): pause automatically when interrupted. On interruption
  end, auto-resume only if playback was active immediately before the
  interruption; otherwise remain paused.
- FR9 — Handle route changes (headphones unplugged, AirPlay/Bluetooth
  connect/disconnect) per platform convention.
- FR10 — Detect a network interruption mid-stream and distinguish
  "stalled, will retry" from "failed, unrecoverable," retrying the former
  with bounded backoff.
- FR11 — Report buffering/stalled state distinctly from user-initiated
  paused state.
- FR12 — Surface typed, actionable errors on unrecoverable failure (bad
  URL, HTTP error, decode failure, unsupported format) — never fail
  silently.
- FR13 — Stopping or replacing the current item cleanly releases all
  resources (player item, network requests, observers) — no leaks.

### Caching (basic, not full offline)

- FR14 — Bytes read during playback are cached to disk so replaying the
  same item shortly after doesn't re-fetch already-fetched ranges.
- FR15 — Cache is size-bounded with an eviction policy (LRU).
- FR16 — Cache respects validity (ETag/Last-Modified) — never knowingly
  serves stale bytes.
- FR17 — A fully-cached item plays with no network at all, even though
  "download for offline" as a deliberate user action is out of V1.

## Non-Goals (V1)

- No queue/playlist management — the host app sequences items; the V1
  controller plays one item at a time.
- No download-for-offline UI/management (later milestone).
- No HLS/adaptive streaming, and no custom adaptive-bitrate logic.
- No DRM/FairPlay.
- No persistence beyond the byte cache — no Core Data/SQLite/SwiftData.
- No mixing, crossfade, or audio effects.

## Non-Functional Requirements

- NFR1 — Framework-added latency to first audio should be measurable and
  small relative to network/server time; requires instrumentation to
  verify, not just assumed.
- NFR2 — Seeking never re-downloads byte ranges already in cache.
- NFR3 — Bounded memory regardless of track length — no requirement to
  hold a full track in memory.
- NFR4 — Bounded disk usage via cache eviction (FR15).
- NFR5 — No file handle/observer/temp-file leaks across repeated
  play/stop/replace cycles — verified by test, not assumed.
- NFR6 — Shared mutable state (player state, cache index) is
  actor-isolated; no data races.
- NFR7 — Public async APIs support cancellation correctly mid-operation.
- NFR8 — Transient network failures retry with bounded backoff before
  surfacing a terminal error.
- NFR9 — A playback session survives backgrounding/foregrounding without
  corrupting state.
- NFR10 — No polling where an observation API (KVO/delegate/async stream)
  exists instead — battery-relevant.
- NFR11 — Core logic (state machine, retry policy, cache eviction) is
  unit-testable without real network or hardware, via injectable seams.
- NFR12 — V1 public API surface is deliberately small: a playback
  controller + cache configuration. Internal subsystems aren't public
  unless a consumer genuinely needs them.

## Networking Dependency Boundary

AudioStreamKit does not duplicate the user's separate SwiftResilience
framework. SwiftResilience is scoped to discrete API request/response
orchestration (retry, dedup, offline request queueing, background
draining, token refresh, observability) and explicitly does not cover byte
range requests, resumable/large downloads, streaming, or media-body
caching. AudioStreamKit owns all actual media-byte transfer, streaming,
and caching. SwiftResilience would only be reused if AudioStreamKit ever
needs a discrete API call (e.g. resolving a manifest/stream URL); no such
call exists in V1.

## Test/Demo Content

No backend exists yet to resolve playable media URLs. Verified-working
open test audio sources (checked 2026-09-11):

- `https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3` —
  progressive MP3 (~8.9MB), `Accept-Ranges: bytes`.
- `https://ia800908.us.archive.org/8/items/testmp3testfile/mpthreetest.mp3`
  — small (~194KB) public-domain MP3, byte-range capable.
- `https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8`
  — Apple's public HLS test manifest (audio+video; not used for V1 since
  HLS is out of scope, but useful later).

Automated tests must not depend on these live URLs — they are for manual
verification and demo purposes only. The test suite needs a local fixture
server or canned responses behind the same seam the resource loader uses.
