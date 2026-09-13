//
//  CacheEntryMetadata.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation

/// One cached item's record, per `streaming-and-caching.md` §2. Persisted to disk as JSON
/// alongside the item's sparse data file, so the cache survives relaunch.
struct CacheEntryMetadata: Sendable, Equatable, Codable {
    let originalURL: URL
    var contentLength: Int64
    var mimeType: String?
    var etag: String?
    var lastModified: String?
    var supportsByteRangeAccess: Bool
    var byteRangesPresent: [ByteRange]
    var lastAccessedAt: Date
}

/// A half-open byte range (`lowerBound..<upperBound`). Not `Range<Int64>` itself — `Range`
/// isn't `Codable`, and this only ever needs to round-trip through JSON and get compared.
struct ByteRange: Sendable, Equatable, Codable {
    let lowerBound: Int64
    let upperBound: Int64

    var asRange: Range<Int64> { lowerBound..<upperBound }

    init(_ range: Range<Int64>) {
        self.lowerBound = range.lowerBound
        self.upperBound = range.upperBound
    }

    init(lowerBound: Int64, upperBound: Int64) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}
