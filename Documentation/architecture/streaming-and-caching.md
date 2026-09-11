# AudioStreamKit V1 — Streaming & Caching Design

Status: Accepted (2026-09-11). Detail behind the `MediaSource`/`MediaCache`
boxes in `high-level-architecture.md`. Rationale for choosing this approach
over the simpler alternative is in `../decisions/ADR-001-resource-loading-strategy.md`.

## 1. Getting AVPlayer to call us

`AVURLAsset` only invokes a custom `AVAssetResourceLoaderDelegate` for URL
schemes it doesn't natively handle. AudioStreamKit rewrites the scheme
(`https://...` -> `astk-https://...`) when constructing the asset, and
rewrites it back to `https://` inside the delegate before issuing the real
`URLSession` request.

## 2. Cache key & on-disk layout

- Cache key = SHA-256 of the canonical remote URL string.
- Per key: one pre-allocated **sparse file** sized to the asset's total
  content length (once known), plus a metadata record:
  `{ originalURL, contentLength, mimeType, etag, lastModified,
  byteRangesPresent: [(start, end)], lastAccessedAt }`.
- Sparse file + range-list means a cached read is a direct file read at
  the requested offset — no chunk reassembly needed.

## 3. `contentInformationRequest`

Must be satisfied before any `dataRequest` on the same loading request.

- If metadata is already cached for this key, answer from the stored
  record immediately.
- Otherwise, probe the origin: try `HEAD`, fall back to a `bytes=0-0`
  ranged `GET` if the origin rejects `HEAD`. Cache the result so the probe
  never repeats for that URL.
- `isByteRangeAccessSupported` must be set to `true`. Missing this causes
  AVPlayer to request the whole file linearly instead of in ranges,
  silently defeating the caching design.

## 4. `dataRequest` — hit / partial hit / miss

For a requested range `[offset, offset+length)`:

- **Full hit** — entire range already in `byteRangesPresent`: read
  directly from the local sparse file, `respond(with:)`, finish. No
  network. This is what makes FR14/FR17 real.
- **Partial or full miss** — diff the requested range against
  `byteRangesPresent` to find the actual gap(s), issue a ranged
  `URLSession` `GET` for just the missing bytes, stream each chunk to
  `dataRequest.respond(with:)` as it arrives *and* write-through to the
  sparse file + extend `byteRangesPresent` in the same step, so the next
  request against this range becomes a hit.

## 5. Concurrent / cancelled requests (seeks)

AVPlayer may have multiple `AVAssetResourceLoadingRequest`s in flight
(read-ahead buffering) and calls `resourceLoader(_:didCancel:)` on one when
a seek supersedes it. Each loading request owns its own tracked task;
cancellation cancels the underlying `URLSessionDataTask`/`Task` immediately
and discards only that request's partial write. Bytes already durably
written by other, completed requests are unaffected. This implements FR13
and NFR7.

## 6. Retry integration

A transient failure on a range fetch goes through `RetryPolicy`
(exponential backoff) and retries only the missing sub-range — never the
whole item, never a fresh full request. After the retry budget is
exhausted, the loading request fails with the underlying error;
`PlaybackEngine` classifies it (recoverable stall vs. terminal failure) and
drives the state machine accordingly (FR10/FR12).

## 7. Cache validation policy (ETag/Last-Modified)

Default policy (revisit if requirements change): validate opportunistically.
If online and a fresh request to the origin returns a different
`ETag`/`Last-Modified` than stored, invalidate and refetch that entry. If
offline or the origin is unreachable, serve the existing cache as-is
rather than failing. Strict validation before every cached play would
defeat FR17 ("plays with no network").

## 8. Eviction (FR15)

LRU at the whole-entry level, not sub-range — evicting partial ranges out
of a sparse file adds real complexity for little benefit at this scale.
Bounded by a configurable `maxCacheSizeBytes` (public cache config).
`lastAccessedAt` updates on every read (playback or revalidation);
over-budget evictions remove least-recently-accessed complete entries
first.

## 9. Concurrency boundary

`MediaCache` is an actor. All range-set/metadata mutations go through it,
including "write bytes, then extend range-set" as one ordered step within
the actor — a range is never marked present before its bytes are durably
written, so a crash mid-write can't leave the metadata claiming data that
isn't on disk. Reads can happen off-actor once the actor hands back a safe
read plan (offset + file handle), since disjoint reads on a sparse file
don't race with each other, only with writes.
