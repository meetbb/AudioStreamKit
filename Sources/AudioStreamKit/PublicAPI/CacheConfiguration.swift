//
//  CacheConfiguration.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation

/// See `Documentation/architecture/public-api.md` §5. Minimal on purpose: validation policy
/// and eviction mechanics are `MediaCache`'s internal concern, not a caller decision in V1.
public struct CacheConfiguration: Sendable, Equatable {
    public let maxSizeBytes: Int

    public init(maxSizeBytes: Int) {
        self.maxSizeBytes = maxSizeBytes
    }

    public static let `default` = CacheConfiguration(maxSizeBytes: 200 * 1024 * 1024)
}
