//
//  PlaybackError.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation

public enum PlaybackError: Error, Sendable, Equatable {
    case invalidURL
    case network(URLError)
    case http(statusCode: Int)
    case decodeFailed
    case unsupportedFormat
    case cancelled
    case audioSessionUnavailable
}

extension PlaybackError: LocalizedError {
    public var errorDescription: String? {
        switch self {
            case .invalidURL: "The media URL is invalid."
            case .network(let urlError): urlError.localizedDescription
            case .http(let statusCode): "Server returned an error (\(statusCode))"
            case .decodeFailed: "The media could not be decoded."
            case .unsupportedFormat: "This media format isn't supported."
            case .cancelled: "Playback was cancelled."
            case .audioSessionUnavailable: "The audio session could not be activated."
        }
    }
}

extension PlaybackError {
    /// Broad grouping a caller can use to tailor user-facing messaging or telemetry without
    /// hand-rolling a `switch` over every case by name — a real gap, caught in review:
    /// `.audioSessionUnavailable` (a system-resource problem) sat flat alongside content
    /// problems (`.decodeFailed`, `.unsupportedFormat`) and network problems (`.network`,
    /// `.http`) with no structural way to tell them apart.
    ///
    /// This is **not** a statement about retry behavior — every `PlaybackError` a caller ever
    /// sees is already terminal (`error-handling-strategy.md` Tier 2): a transient failure worth
    /// retrying automatically is absorbed internally by `RetryPolicy`/`FailureClassifier` before
    /// it can ever surface as a `PlaybackError` at all. Grouping these cases by *what kind of
    /// problem occurred* is a display/diagnostics convenience only.
    ///
    /// Additive only — no existing case was renamed, removed, or reordered, so this doesn't
    /// change what any existing `switch` over `PlaybackError` itself needs to handle.
    public enum Category: Sendable, Equatable {
        /// A problem with the media content or its identifying URL.
        case content
        /// A problem reaching or receiving from the server.
        case network
        /// A problem with a system resource this framework doesn't own outright (e.g. another
        /// app holding exclusive audio).
        case systemResource
        case cancelled
    }

    public var category: Category {
        switch self {
        case .invalidURL, .decodeFailed, .unsupportedFormat:
            .content
        case .network, .http:
            .network
        case .audioSessionUnavailable:
            .systemResource
        case .cancelled:
            .cancelled
        }
    }
}
