//
//  MediaCache.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation
import CryptoKit

/// On-disk byte-range cache for streamed media. See `Documentation/architecture/streaming-and-caching.md`
/// §2, §7-9. An `actor`: all metadata/range-set mutation goes through it, and a range is
/// never marked present before its bytes are durably written (§9).
///
/// Reads for an already-cached range don't need to go through the actor — `readPlan(for:url:)`
/// hands back an offset-explicit plan the caller can read off-actor (`concurrency-model.md`
/// §5), since disjoint reads on the sparse file don't race with each other, only with writes.
actor MediaCache {

    private let configuration: CacheConfiguration
    private let rootDirectory: URL
    private let fileManager: FileManager

    /// In-memory index. Populated lazily from each entry's on-disk JSON sidecar the first
    /// time that entry is touched this process's lifetime — see the eviction limitation
    /// noted on `evictIfNeeded()`.
    private var metadataByKey: [String: CacheEntryMetadata] = [:]

    init(
        configuration: CacheConfiguration = .default,
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
        try? fileManager.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Cache key

    nonisolated static func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Metadata

    func metadata(for url: URL) -> CacheEntryMetadata? {
        resolvedMetadata(for: Self.cacheKey(for: url))
    }

    /// Creates the entry (preallocating its sparse data file) if this key is new, or updates
    /// the stored fields of an existing entry without touching `byteRangesPresent` — call
    /// `invalidate(for:)` first if the caller has already decided this entry is stale
    /// (`streaming-and-caching.md` §7).
    @discardableResult
    func storeMetadata(
        originalURL: URL,
        contentLength: Int64,
        mimeType: String?,
        etag: String?,
        lastModified: String?,
        supportsByteRangeAccess: Bool
    ) throws -> CacheEntryMetadata {
        let key = Self.cacheKey(for: originalURL)
        let dataURL = dataFileURL(for: key)

        if var existing = resolvedMetadata(for: key) {
            existing.contentLength = contentLength
            existing.mimeType = mimeType
            existing.etag = etag
            existing.lastModified = lastModified
            existing.supportsByteRangeAccess = supportsByteRangeAccess
            if !fileManager.fileExists(atPath: dataURL.path) {
                try ensureDataFile(at: dataURL, sizedTo: contentLength)
            }
            metadataByKey[key] = existing
            try persist(existing, key: key)
            return existing
        }

        try ensureDataFile(at: dataURL, sizedTo: contentLength)
        let metadata = CacheEntryMetadata(
            originalURL: originalURL,
            contentLength: contentLength,
            mimeType: mimeType,
            etag: etag,
            lastModified: lastModified,
            supportsByteRangeAccess: supportsByteRangeAccess,
            byteRangesPresent: [],
            lastAccessedAt: Date()
        )
        metadataByKey[key] = metadata
        try persist(metadata, key: key)
        return metadata
    }

    /// Discards a stale entry entirely (data file + metadata), per the ETag/Last-Modified
    /// policy in `streaming-and-caching.md` §7. The next `storeMetadata` for this URL starts
    /// fresh. Deciding *when* an entry is stale is the caller's job — `MediaCache` only
    /// provides the mechanism.
    func invalidate(for url: URL) {
        let key = Self.cacheKey(for: url)
        metadataByKey.removeValue(forKey: key)
        try? fileManager.removeItem(at: dataFileURL(for: key))
        try? fileManager.removeItem(at: metadataFileURL(for: key))
    }

    // MARK: - Range queries

    /// Sub-ranges of `requested` not yet present in the cache, in ascending order. An empty
    /// result means `requested` is a full hit.
    func missingRanges(in requested: Range<Int64>, for url: URL) -> [Range<Int64>] {
        let present = (resolvedMetadata(for: Self.cacheKey(for: url))?.byteRangesPresent ?? [])
            .map(\.asRange)
            .filter { $0.overlaps(requested) }
            .sorted { $0.lowerBound < $1.lowerBound }

        var missing: [Range<Int64>] = []
        var cursor = requested.lowerBound
        for range in present {
            let clippedLower = Swift.max(range.lowerBound, requested.lowerBound)
            let clippedUpper = Swift.min(range.upperBound, requested.upperBound)
            if cursor < clippedLower {
                missing.append(cursor..<clippedLower)
            }
            cursor = Swift.max(cursor, clippedUpper)
        }
        if cursor < requested.upperBound {
            missing.append(cursor..<requested.upperBound)
        }
        return missing
    }

    /// A safe, offset-explicit read plan for `requested`, or `nil` if any part of it is
    /// missing. See the type's header comment for why this is safe to read off-actor.
    func readPlan(for requested: Range<Int64>, url: URL) -> CacheReadPlan? {
        guard missingRanges(in: requested, for: url).isEmpty else { return nil }
        let key = Self.cacheKey(for: url)
        return CacheReadPlan(fileURL: dataFileURL(for: key), offset: requested.lowerBound, length: Int64(requested.count))
    }

    // MARK: - Writing

    /// Writes `data` at `offset` and marks that range present, in that order — bytes are
    /// durably written before the range-set says they're there (`streaming-and-caching.md` §9).
    func write(_ data: Data, at offset: Int64, for url: URL) throws {
        let key = Self.cacheKey(for: url)
        guard var metadata = resolvedMetadata(for: key) else {
            throw MediaCacheError.noMetadata
        }

        let handle = try FileHandle(forWritingTo: dataFileURL(for: key))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        handle.write(data)

        let writtenRange = offset..<(offset + Int64(data.count))
        metadata.byteRangesPresent = Self.merging(writtenRange, into: metadata.byteRangesPresent)
        metadataByKey[key] = metadata
        try persist(metadata, key: key)
    }

    // MARK: - Access tracking / eviction

    /// Updates `lastAccessedAt` and evicts if the cache is now over budget.
    func recordAccess(for url: URL) {
        let key = Self.cacheKey(for: url)
        guard var metadata = resolvedMetadata(for: key) else { return }
        metadata.lastAccessedAt = Date()
        metadataByKey[key] = metadata
        try? persist(metadata, key: key)
        evictIfNeeded()
    }

    /// LRU at the whole-entry level (`streaming-and-caching.md` §8). Only considers entries
    /// already loaded into `metadataByKey` this process's lifetime, not every entry ever
    /// persisted to disk — a cold entry nothing has touched since launch isn't a candidate
    /// until something touches it. A full-disk startup scan would close this gap; not needed
    /// for the eviction mechanism itself to be correct, so deferred.
    private func evictIfNeeded() {
        var totalSize = metadataByKey.values.reduce(Int64(0)) { $0 + $1.contentLength }
        guard totalSize > configuration.maxSizeBytes else { return }

        let oldestFirst = metadataByKey.sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
        for (key, metadata) in oldestFirst {
            guard totalSize > configuration.maxSizeBytes else { break }
            metadataByKey.removeValue(forKey: key)
            try? fileManager.removeItem(at: dataFileURL(for: key))
            try? fileManager.removeItem(at: metadataFileURL(for: key))
            totalSize -= metadata.contentLength
        }
    }

    // MARK: - Range merging

    private static func merging(_ newRange: Range<Int64>, into existing: [ByteRange]) -> [ByteRange] {
        var ranges = existing.map(\.asRange)
        ranges.append(newRange)
        ranges.sort { $0.lowerBound < $1.lowerBound }

        var merged: [Range<Int64>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<Swift.max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged.map(ByteRange.init)
    }

    // MARK: - Disk layout

    private static func defaultRootDirectory(fileManager: FileManager) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return caches.appendingPathComponent("AudioStreamKitMediaCache", isDirectory: true)
    }

    private func dataFileURL(for key: String) -> URL {
        rootDirectory.appendingPathComponent(key).appendingPathExtension("data")
    }

    private func metadataFileURL(for key: String) -> URL {
        rootDirectory.appendingPathComponent(key).appendingPathExtension("json")
    }

    private func ensureDataFile(at fileURL: URL, sizedTo contentLength: Int64) throws {
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                throw MediaCacheError.dataFileCreationFailed
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(contentLength))
    }

    private func resolvedMetadata(for key: String) -> CacheEntryMetadata? {
        if let cached = metadataByKey[key] {
            return cached
        }
        guard let loaded = try? loadFromDisk(key: key) else { return nil }
        metadataByKey[key] = loaded
        return loaded
    }

    private func persist(_ metadata: CacheEntryMetadata, key: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: metadataFileURL(for: key), options: .atomic)
    }

    private func loadFromDisk(key: String) throws -> CacheEntryMetadata {
        let data = try Data(contentsOf: metadataFileURL(for: key))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CacheEntryMetadata.self, from: data)
    }
}

/// An offset-explicit plan for reading an already-cached range. Safe to use off-actor:
/// each call opens its own `FileHandle`, so concurrent reads at different offsets never
/// share mutable read-position state (`concurrency-model.md` §5).
struct CacheReadPlan: Sendable {
    let fileURL: URL
    let offset: Int64
    let length: Int64

    func read() throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return handle.readData(ofLength: Int(length))
    }
}

enum MediaCacheError: Error, Sendable, Equatable {
    /// `write(_:at:for:)` was called before `storeMetadata` ever ran for this URL.
    case noMetadata
    case dataFileCreationFailed
}
