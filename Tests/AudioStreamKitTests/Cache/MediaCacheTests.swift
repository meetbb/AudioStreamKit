//
//  MediaCacheTests.swift
//  AudioStreamKitTests
//
//  Created by Meet Brahmbhatt on 13/09/26.
//

import XCTest
@testable import AudioStreamKit

final class MediaCacheTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeCache(maxSizeBytes: Int = 200 * 1024 * 1024) -> MediaCache {
        MediaCache(
            configuration: CacheConfiguration(maxSizeBytes: maxSizeBytes),
            rootDirectory: tempDirectory
        )
    }

    private let url = URL(string: "https://example.com/track.mp3")!

    // MARK: - Cache key

    /// Checks that the same track address always produces the same cache key.
    func test_cacheKey_isDeterministic() {
        XCTAssertEqual(MediaCache.cacheKey(for: url), MediaCache.cacheKey(for: url))
    }

    /// Checks that two different track addresses produce two different cache keys.
    func test_cacheKey_differsForDifferentURLs() {
        let other = URL(string: "https://example.com/other.mp3")!
        XCTAssertNotEqual(MediaCache.cacheKey(for: url), MediaCache.cacheKey(for: other))
    }

    // MARK: - storeMetadata

    /// Checks that saving info about a new track (size, type, etc.) can be read back correctly,
    /// with nothing marked as downloaded yet.
    func test_storeMetadata_newEntry_isRetrievable() async throws {
        let cache = makeCache()
        try await cache.storeMetadata(originalURL: url, contentLength: 1_000, mimeType: "audio/mpeg", etag: "v1", lastModified: nil, supportsByteRangeAccess: true)

        let metadata = await cache.metadata(for: url)
        XCTAssertEqual(metadata?.contentLength, 1_000)
        XCTAssertEqual(metadata?.mimeType, "audio/mpeg")
        XCTAssertEqual(metadata?.etag, "v1")
        XCTAssertEqual(metadata?.byteRangesPresent, [])
    }

    /// Checks that updating a track's info (like a changed version tag) doesn't wipe out what's
    /// already been downloaded for it.
    func test_storeMetadata_existingEntry_updatesFieldsWithoutClearingRanges() async throws {
        let cache = makeCache()
        try await cache.storeMetadata(originalURL: url, contentLength: 1_000, mimeType: "audio/mpeg", etag: "v1", lastModified: nil, supportsByteRangeAccess: true)
        try await cache.write(Data(repeating: 0, count: 100), at: 0, for: url)

        try await cache.storeMetadata(originalURL: url, contentLength: 1_000, mimeType: "audio/mpeg", etag: "v2", lastModified: nil, supportsByteRangeAccess: true)

        let metadata = await cache.metadata(for: url)
        XCTAssertEqual(metadata?.etag, "v2")
        XCTAssertEqual(metadata?.byteRangesPresent, [ByteRange(0..<100)])
    }

    // MARK: - missingRanges / write / readPlan

    /// Checks that before any bytes are downloaded, the whole requested chunk is reported as
    /// missing.
    func test_missingRanges_beforeAnyWrite_isEntireRequestedRange() async throws {
        let cache = makeCache()
        try await cache.storeMetadata(originalURL: url, contentLength: 1_000, mimeType: nil, etag: nil, lastModified: nil, supportsByteRangeAccess: true)

        let missing = await cache.missingRanges(in: 0..<500, for: url)
        XCTAssertEqual(missing, [0..<500])
    }

    /// Checks that after downloading part of a track, only the parts still missing are
    /// reported — the part already saved is correctly excluded.
    func test_write_thenMissingRanges_reflectsWhatWasWritten() async throws {
        let cache = makeCache()
        try await cache.storeMetadata(originalURL: url, contentLength: 1_000, mimeType: nil, etag: nil, lastModified: nil, supportsByteRangeAccess: true)
        try await cache.write(Data(repeating: 0xFF, count: 200), at: 100, for: url)

        // Requested [0, 500) with [100, 300) present -> gaps before and after.
        let missing = await cache.missingRanges(in: 0..<500, for: url)
        XCTAssertEqual(missing, [0..<100, 300..<500])
    }

    /// Checks that two back-to-back downloaded chunks are combined into one continuous saved
    /// range, instead of being tracked as separate pieces.
    func test_write_adjacentRanges_mergeIntoOne() async throws {
        let cache = makeCache()
        try await cache.storeMetadata(originalURL: url, contentLength: 1_000, mimeType: nil, etag: nil, lastModified: nil, supportsByteRangeAccess: true)
        try await cache.write(Data(repeating: 0, count: 100), at: 0, for: url)
        try await cache.write(Data(repeating: 0, count: 100), at: 100, for: url)

        let metadata = await cache.metadata(for: url)
        XCTAssertEqual(metadata?.byteRangesPresent, [ByteRange(0..<200)])
    }

    /// Checks that reading back a fully saved chunk of a track returns exactly the bytes that
    /// were written.
    func test_readPlan_fullHit_returnsPlanReadingWhatWasWritten() async throws {
        let cache = makeCache()
        try await cache.storeMetadata(originalURL: url, contentLength: 1_000, mimeType: nil, etag: nil, lastModified: nil, supportsByteRangeAccess: true)
        let written = Data("hello world".utf8)
        try await cache.write(written, at: 10, for: url)

        let plan = await cache.readPlan(for: 10..<Int64(10 + written.count), url: url)
        let readBack = try XCTUnwrap(plan).read()
        XCTAssertEqual(readBack, written)
    }

    /// Checks that asking to read a chunk that's only partly downloaded correctly returns
    /// nothing, rather than incomplete or wrong data.
    func test_readPlan_partialHit_returnsNil() async throws {
        let cache = makeCache()
        try await cache.storeMetadata(originalURL: url, contentLength: 1_000, mimeType: nil, etag: nil, lastModified: nil, supportsByteRangeAccess: true)
        try await cache.write(Data(repeating: 0, count: 50), at: 0, for: url)

        let plan = await cache.readPlan(for: 0..<100, url: url)
        XCTAssertNil(plan)
    }

    /// Checks that trying to save downloaded bytes for a track we never registered first fails
    /// clearly, instead of silently doing the wrong thing.
    func test_write_withoutPriorMetadata_throwsNoMetadata() async {
        let cache = makeCache()
        do {
            try await cache.write(Data([1, 2, 3]), at: 0, for: url)
            XCTFail("expected write to throw")
        } catch let error as MediaCacheError {
            XCTAssertEqual(error, .noMetadata)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - invalidate

    /// Checks that invalidating a track's cache entry removes it completely, as if it had
    /// never been downloaded.
    func test_invalidate_removesEntryEntirely() async throws {
        let cache = makeCache()
        try await cache.storeMetadata(originalURL: url, contentLength: 1_000, mimeType: nil, etag: "v1", lastModified: nil, supportsByteRangeAccess: true)
        try await cache.write(Data(repeating: 0, count: 100), at: 0, for: url)

        await cache.invalidate(for: url)

        let metadata = await cache.metadata(for: url)
        XCTAssertNil(metadata)
    }

    // MARK: - Persistence across instances

    /// Checks that what's downloaded is still there even after the cache is closed and
    /// reopened — like restarting the app.
    func test_metadata_persistsAcrossCacheInstances() async throws {
        let firstCache = makeCache()
        try await firstCache.storeMetadata(originalURL: url, contentLength: 1_000, mimeType: "audio/mpeg", etag: "v1", lastModified: nil, supportsByteRangeAccess: true)
        try await firstCache.write(Data(repeating: 0, count: 100), at: 0, for: url)

        let secondCache = makeCache()
        let metadata = await secondCache.metadata(for: url)
        XCTAssertEqual(metadata?.mimeType, "audio/mpeg")
        XCTAssertEqual(metadata?.byteRangesPresent, [ByteRange(0..<100)])
    }

    // MARK: - Eviction

    /// Checks that when the cache grows past its size limit, the oldest unused track is the
    /// one removed to make room, not a more recently used one.
    func test_recordAccess_evictsLeastRecentlyAccessed_whenOverBudget() async throws {
        let cache = makeCache(maxSizeBytes: 150)
        let older = URL(string: "https://example.com/older.mp3")!
        let newer = URL(string: "https://example.com/newer.mp3")!

        try await cache.storeMetadata(originalURL: older, contentLength: 100, mimeType: nil, etag: nil, lastModified: nil, supportsByteRangeAccess: true)
        await cache.recordAccess(for: older)

        try await cache.storeMetadata(originalURL: newer, contentLength: 100, mimeType: nil, etag: nil, lastModified: nil, supportsByteRangeAccess: true)
        await cache.recordAccess(for: newer)

        // Total (200) now exceeds the 150-byte budget; `older` was accessed first, so it's evicted.
        let olderMetadata = await cache.metadata(for: older)
        let newerMetadata = await cache.metadata(for: newer)
        XCTAssertNil(olderMetadata)
        XCTAssertNotNil(newerMetadata)
    }

    /// Checks that nothing gets removed from the cache while it's still comfortably under its
    /// size limit.
    func test_recordAccess_underBudget_evictsNothing() async throws {
        let cache = makeCache(maxSizeBytes: 1_000)
        try await cache.storeMetadata(originalURL: url, contentLength: 100, mimeType: nil, etag: nil, lastModified: nil, supportsByteRangeAccess: true)

        await cache.recordAccess(for: url)

        let metadata = await cache.metadata(for: url)
        XCTAssertNotNil(metadata)
    }
}
