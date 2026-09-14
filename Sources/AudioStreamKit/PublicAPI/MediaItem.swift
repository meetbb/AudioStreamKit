//
//  MediaItem.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation

/// What a caller hands to `AudioPlayer.load(_:)`. See `Documentation/architecture/public-api.md`
/// §4. All metadata is optional so `MediaItem(url: someURL)` still plays — missing metadata
/// just means Now Playing (FR6) shows less, never a load failure.
public struct MediaItem: Sendable, Equatable {
    public let url: URL
    public let title: String?
    public let artist: String?

    /// In-memory artwork, not a URL — fetching remote artwork is a separate concern
    /// (its own network fetch/caching story) that this framework doesn't own in V1.
    public let artworkData: Data?

    public init(url: URL, title: String? = nil, artist: String? = nil, artworkData: Data? = nil) {
        self.url = url
        self.title = title
        self.artist = artist
        self.artworkData = artworkData
    }
}
