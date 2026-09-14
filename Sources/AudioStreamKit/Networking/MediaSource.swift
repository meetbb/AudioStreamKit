//
//  MediaSource.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation
import AVFoundation

/// Reports `MediaSource`'s internal retry lifecycle (`fetchWithRetry`) outward, since nothing
/// about it is otherwise observable from outside `MediaSource` itself. `AnyObject`-bound so
/// `MediaSource` can hold its delegate `weak` — `PlaybackEngine` (the only real conformer)
/// owns the `MediaSource` it sets itself as delegate on, so a strong reference back would be
/// a retain cycle.
///
/// `async` requirements, not a `Task`-wrapped fire-and-forget callback: `fetchWithRetry` is
/// already running inside its own `async` context, so it can simply `await` these directly —
/// unlike the synchronous KVO/`NotificationCenter` callbacks `PlaybackEngine` bridges
/// elsewhere, there's no non-async boundary here to hop across.
protocol MediaSourceDelegate: AnyObject {
    /// The first retryable failure on a range fetch — maps to `.networkStallBegan`
    /// (`playback-state-machine.md` §2).
    func mediaSourceDidBeginStall() async

    /// A range fetch that had previously stalled just succeeded — maps to
    /// `.networkStallRecovered`. Never called for a fetch that succeeded on its first try.
    func mediaSourceDidRecoverFromStall() async

    /// The item-scoped retry budget (`error-handling-strategy.md` §6) is exhausted — maps to
    /// `.retryBudgetExhausted(PlaybackError)`. `error` is already classified, ready to hand
    /// straight to the state machine.
    func mediaSource(_ mediaSource: MediaSource, didExhaustRetryBudgetWith error: PlaybackError) async
}

/// Intercepts `AVPlayer`'s resource loading so AudioStreamKit issues the actual network
/// requests itself, rather than letting AVFoundation stream from the remote URL opaquely.
/// See `ADR-001-resource-loading-strategy.md` and `streaming-and-caching.md`.
///
/// Not an `actor`: `AVAssetResourceLoaderDelegate` requires conformance to
/// `NSObjectProtocol`, which a Swift `actor` cannot satisfy. Safety for this type's own
/// mutable state instead comes from two things working together (`concurrency-model.md`
/// §3): a dedicated serial delegate queue (so AVFoundation itself never calls two delegate
/// methods concurrently) and a nested `actor` (`LoadingRequestTracker`) that owns the
/// loadingRequest -> Task bookkeeping needed for correct cancellation.
///
/// `contentInformationRequest` answers from `MediaCache` when cached, otherwise probes the
/// origin and stores the result. On a cache hit it also opportunistically revalidates
/// against the origin (`streaming-and-caching.md` §7) before answering. `dataRequest` diffs
/// the requested range against the cache and walks it as present/missing segments,
/// responding from disk for hits and fetching+caching gaps (write-through, best-effort) —
/// see `streaming-and-caching.md` §4.
///
/// `@unchecked Sendable`: needed so the tracked-`Task`s this type hands out can capture
/// `self` under Swift 6 strict concurrency (the compiler can't infer `Sendable` through
/// `NSObject`). Safe because almost every stored property is `let`-bound and either itself
/// `Sendable` (`URLSession`, `RetryPolicy`, `DispatchQueue`) or an `actor`
/// (`tracker`, `retryState`). The one exception is `delegate` — a `weak var` — but it's
/// written exactly once, synchronously, by `PlaybackEngine` immediately after constructing
/// this instance and before any concurrent work has started; every read of it thereafter
/// happens no earlier than that write could have completed, so there's no actual race despite
/// the property being mutable.
final class MediaSource: NSObject, @unchecked Sendable {

    private static let rewrittenHTTPSScheme = "astk-https"
    private static let rewrittenHTTPScheme = "astk-http"

    private let session: URLSession
    private let retryPolicy: RetryPolicy
    private let mediaCache: MediaCache
    private let delegateQueue = DispatchQueue(label: "com.audiostreamkit.mediasource.delegate")
    private let tracker = LoadingRequestTracker()

    /// Item-scoped retry state: one rolling attempt counter for whatever item is currently
    /// loaded, reset on `makeAsset(for:)` (a fresh `.loadRequested`) and on every
    /// successful range fetch. See `error-handling-strategy.md` §6.
    private let retryState = RetryState()

    /// Reports stall/recovery/exhaustion signals from `fetchWithRetry` outward — see
    /// `MediaSourceDelegate`. `weak` so `MediaSource` never keeps `PlaybackEngine` (its owner)
    /// alive; see the type's header comment for why this being mutable doesn't threaten
    /// `@unchecked Sendable`.
    weak var delegate: MediaSourceDelegate?

    init(session: URLSession = .shared, retryPolicy: RetryPolicy = .default, mediaCache: MediaCache = MediaCache()) {
        self.session = session
        self.retryPolicy = retryPolicy
        self.mediaCache = mediaCache
    }

    /// Builds an `AVURLAsset` for `url` wired to this instance as its resource-loader
    /// delegate, and resets the retry budget for the new item.
    func makeAsset(for url: URL) throws -> AVURLAsset {
        guard let rewritten = Self.rewriteToCustomScheme(url) else {
            throw PlaybackError.invalidURL
        }
        Task { await retryState.reset() }
        let asset = AVURLAsset(url: rewritten)
        asset.resourceLoader.setDelegate(self, queue: delegateQueue)
        return asset
    }

    /// Cancels every loading request currently tracked (e.g. on `.stopRequested` /
    /// `.loadRequested`, per `concurrency-model.md` §6). Callers don't need to await this;
    /// cancellation is fire-and-forget from their perspective.
    func cancelAll() {
        Task { await tracker.cancelAll() }
    }

    // MARK: - Scheme rewriting (streaming-and-caching.md §1)

    static func rewriteToCustomScheme(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = rewrittenHTTPSScheme
        case "http": components.scheme = rewrittenHTTPScheme
        default: return nil
        }
        return components.url
    }

    static func rewriteToRealScheme(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case rewrittenHTTPSScheme: components.scheme = "https"
        case rewrittenHTTPScheme: components.scheme = "http"
        default: return nil
        }
        return components.url
    }
}

// MARK: - AVAssetResourceLoaderDelegate

extension MediaSource: AVAssetResourceLoaderDelegate {

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              let realURL = Self.rewriteToRealScheme(requestURL) else {
            loadingRequest.finishLoading(with: PlaybackError.invalidURL)
            return false
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.fulfill(loadingRequest, realURL: realURL)
        }
        Task { await tracker.register(task, for: loadingRequest) }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        Task { await tracker.cancel(loadingRequest) }
    }
}

// MARK: - Fulfilling a loading request

private extension MediaSource {

    func fulfill(_ loadingRequest: AVAssetResourceLoadingRequest, realURL: URL) async {
        defer { Task { await tracker.remove(loadingRequest) } }

        if let infoRequest = loadingRequest.contentInformationRequest {
            do {
                try await populateContentInformation(infoRequest, url: realURL)
            } catch is CancellationError {
                return
            } catch {
                report(error, to: loadingRequest)
                return
            }
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }

        do {
            try await fulfillDataRequest(dataRequest, url: realURL)
            try Task.checkCancellation()
            loadingRequest.finishLoading()
        } catch is CancellationError {
            // Deliberately cancelled (seek/stop). `didCancel`/`cancelAll` already own
            // discarding this request — don't report a spurious failure on top of that.
        } catch {
            report(error, to: loadingRequest)
        }
    }

    func report(_ error: Error, to loadingRequest: AVAssetResourceLoadingRequest) {
        let classification = FailureClassifier.classify(error)
        loadingRequest.finishLoading(with: classification.playbackError)
    }
}

// MARK: - contentInformationRequest (streaming-and-caching.md §3)

private extension MediaSource {

    /// Answers from `MediaCache` if this URL is already cached, opportunistically
    /// revalidating first (`streaming-and-caching.md` §7); otherwise probes the origin fresh
    /// and stores the result for next time.
    func populateContentInformation(
        _ infoRequest: AVAssetResourceLoadingContentInformationRequest,
        url: URL
    ) async throws {
        if let cached = await mediaCache.metadata(for: url) {
            let metadata = await revalidate(cached, url: url)
            apply(metadata, to: infoRequest)
            await mediaCache.recordAccess(for: url)
            return
        }

        let probe = try await probe(url: url)
        let stored = try await mediaCache.storeMetadata(
            originalURL: url,
            contentLength: probe.contentLength,
            mimeType: probe.mimeType,
            etag: probe.etag,
            lastModified: probe.lastModified,
            supportsByteRangeAccess: probe.supportsByteRanges
        )
        apply(stored, to: infoRequest)
        await mediaCache.recordAccess(for: url)
    }

    /// Opportunistic revalidation (`streaming-and-caching.md` §7): if `cached` has a stored
    /// `etag`/`lastModified`, probes the origin fresh and compares. A changed validator
    /// invalidates the entry (discarding its cached bytes, per `MediaCache.invalidate`) and
    /// stores the fresh probe result in its place, so `dataRequest` refetches from scratch.
    /// An unreachable origin, or a cached entry with no validator to compare against, means
    /// the existing entry is returned as-is — trusting the cache rather than failing keeps
    /// offline playback working (FR17).
    func revalidate(_ cached: CacheEntryMetadata, url: URL) async -> CacheEntryMetadata {
        guard cached.etag != nil || cached.lastModified != nil else { return cached }
        guard let probe = try? await probe(url: url) else { return cached }
        guard probe.etag != cached.etag || probe.lastModified != cached.lastModified else { return cached }

        await mediaCache.invalidate(for: url)
        guard let stored = try? await mediaCache.storeMetadata(
            originalURL: url,
            contentLength: probe.contentLength,
            mimeType: probe.mimeType,
            etag: probe.etag,
            lastModified: probe.lastModified,
            supportsByteRangeAccess: probe.supportsByteRanges
        ) else { return cached }
        return stored
    }

    func apply(_ metadata: CacheEntryMetadata, to infoRequest: AVAssetResourceLoadingContentInformationRequest) {
        infoRequest.contentType = metadata.mimeType
        infoRequest.contentLength = metadata.contentLength
        infoRequest.isByteRangeAccessSupported = metadata.supportsByteRangeAccess
    }

    struct ProbeResult {
        let mimeType: String?
        let contentLength: Int64
        let supportsByteRanges: Bool
        let etag: String?
        let lastModified: String?
    }

    func probe(url: URL) async throws -> ProbeResult {
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"

        if let result = try? await performProbeRequest(headRequest) {
            return result
        }

        // Origin rejected HEAD (or it errored) — fall back to a minimal ranged GET, per
        // streaming-and-caching.md §3.
        var rangedGET = URLRequest(url: url)
        rangedGET.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        return try await performProbeRequest(rangedGET)
    }

    func performProbeRequest(_ request: URLRequest) async throws -> ProbeResult {
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlaybackError.decodeFailed
        }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPStatusError(statusCode: http.statusCode)
        }
        let supportsByteRanges = http.statusCode == 206
            || http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        return ProbeResult(
            mimeType: http.mimeType,
            contentLength: totalContentLength(from: http),
            supportsByteRanges: supportsByteRanges,
            etag: http.value(forHTTPHeaderField: "Etag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }

    func totalContentLength(from response: HTTPURLResponse) -> Int64 {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let totalString = contentRange.split(separator: "/").last,
           let total = Int64(totalString) {
            return total
        }
        return response.expectedContentLength
    }
}

// MARK: - dataRequest (streaming-and-caching.md §4, §6)

/// A contiguous piece of a requested range: already in the cache, or not.
/// `MediaSource.segments(of:missing:)` is a pure function purely so it's unit-testable
/// without a real cache or network.
extension MediaSource {
    enum RangeSegment: Equatable {
        case present(Range<Int64>)
        case missing(Range<Int64>)

        var range: Range<Int64> {
            switch self {
            case .present(let range), .missing(let range): return range
            }
        }
    }

    /// Tiles `range` into ascending, non-overlapping segments, alternating `.present` (not in
    /// `missing`) and `.missing`, so `dataRequest.respond(with:)` can be called once per
    /// segment in order.
    static func segments(of range: Range<Int64>, missing: [Range<Int64>]) -> [RangeSegment] {
        var result: [RangeSegment] = []
        var cursor = range.lowerBound
        for gap in missing.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if cursor < gap.lowerBound {
                result.append(.present(cursor..<gap.lowerBound))
            }
            result.append(.missing(gap))
            cursor = gap.upperBound
        }
        if cursor < range.upperBound {
            result.append(.present(cursor..<range.upperBound))
        }
        return result
    }
}

private extension MediaSource {

    /// Fulfills `dataRequest` by walking it as present/missing segments against `MediaCache`:
    /// present segments are read from disk, missing segments are fetched (with retry) and
    /// written through (best-effort) before being handed to AVFoundation. Calls
    /// `dataRequest.respond(with:)` once per segment, in order, rather than waiting for the
    /// whole range.
    func fulfillDataRequest(_ dataRequest: AVAssetResourceLoadingDataRequest, url: URL) async throws {
        let knownContentLength = await mediaCache.metadata(for: url)?.contentLength
        guard let range = requestedRange(for: dataRequest, knownContentLength: knownContentLength) else {
            // Open-ended request with no known total length yet — can't cache-diff
            // meaningfully; fetch directly.
            let data = try await fetchWithRetry(from: dataRequest.requestedOffset, upTo: nil, url: url)
            dataRequest.respond(with: data)
            return
        }

        let missing = await mediaCache.missingRanges(in: range, for: url)
        for segment in Self.segments(of: range, missing: missing) {
            try Task.checkCancellation()
            if case .present(let subrange) = segment, let plan = await mediaCache.readPlan(for: subrange, url: url) {
                dataRequest.respond(with: try plan.read())
            } else {
                let subrange = segment.range
                let data = try await fetchWithRetry(from: subrange.lowerBound, upTo: subrange.upperBound, url: url)
                try? await mediaCache.write(data, at: subrange.lowerBound, for: url)
                dataRequest.respond(with: data)
            }
        }
        await mediaCache.recordAccess(for: url)
    }

    func requestedRange(for dataRequest: AVAssetResourceLoadingDataRequest, knownContentLength: Int64?) -> Range<Int64>? {
        let offset = dataRequest.requestedOffset
        if dataRequest.requestsAllDataToEndOfResource {
            guard let knownContentLength else { return nil }
            return offset..<knownContentLength
        }
        return offset..<(offset + Int64(dataRequest.requestedLength))
    }

    /// Fetches `[lowerBound, upperBoundExclusive)` (or to the end of the resource if
    /// `upperBoundExclusive` is nil), retrying transient failures against the item-scoped
    /// budget. Reports the stall lifecycle to `delegate` as it happens: the *first* retryable
    /// failure (`didStall` flips `true`) reports `mediaSourceDidBeginStall()`; a later success
    /// only reports `mediaSourceDidRecoverFromStall()` if this call actually stalled (a
    /// first-try success isn't a "recovery" from anything); exhausting the budget reports
    /// `mediaSource(_:didExhaustRetryBudgetWith:)` with the classified error before throwing.
    func fetchWithRetry(from lowerBound: Int64, upTo upperBoundExclusive: Int64?, url: URL) async throws -> Data {
        var didStall = false
        while true {
            try Task.checkCancellation()
            do {
                let data = try await fetchRange(from: lowerBound, upTo: upperBoundExclusive, url: url)
                await retryState.reset()
                if didStall {
                    await delegate?.mediaSourceDidRecoverFromStall()
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let classification = FailureClassifier.classify(error)
                guard case .retryable = classification else {
                    throw error
                }
                if !didStall {
                    didStall = true
                    await delegate?.mediaSourceDidBeginStall()
                }
                let attempt = await retryState.recordFailureAndNextAttempt()
                guard retryPolicy.hasBudget(forAttempt: attempt) else {
                    await delegate?.mediaSource(self, didExhaustRetryBudgetWith: classification.playbackError)
                    throw error
                }
                try await Task.sleep(for: .seconds(retryPolicy.delay(forAttempt: attempt)))
            }
        }
    }

    func fetchRange(from lowerBound: Int64, upTo upperBoundExclusive: Int64?, url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        if let upperBoundExclusive {
            request.setValue("bytes=\(lowerBound)-\(upperBoundExclusive - 1)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(lowerBound)-", forHTTPHeaderField: "Range")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlaybackError.decodeFailed
        }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPStatusError(statusCode: http.statusCode)
        }
        return data
    }
}

// MARK: - Item-scoped retry state

/// Owns the rolling attempt counter for `error-handling-strategy.md` §6's item-scoped
/// retry budget. An `actor` because it's mutated from whichever tracked `Task` currently
/// owns a range fetch, and those can run concurrently (read-ahead buffering).
private actor RetryState {
    private var attempt = 0

    func reset() {
        attempt = 0
    }

    func recordFailureAndNextAttempt() -> Int {
        attempt += 1
        return attempt
    }
}

// MARK: - Loading-request tracker (concurrency-model.md §3, §6)

/// Owns the `AVAssetResourceLoadingRequest -> Task` bookkeeping so `didCancel` can cancel
/// exactly the right in-flight work, and `cancelAll` can tear down every tracked request
/// for the current item.
private actor LoadingRequestTracker {
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func register(_ task: Task<Void, Never>, for loadingRequest: AVAssetResourceLoadingRequest) {
        tasks[ObjectIdentifier(loadingRequest)] = task
    }

    func remove(_ loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))
    }

    func cancel(_ loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }
}
