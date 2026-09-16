//
//  PlaybackState.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation

/// See `Documentation/architecture/public-api.md` §2 — the state type is public even though
/// the engine driving it (`PlaybackStateMachine`) is not.
public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case buffering
    case playing
    case paused
    case stalled
    case failed(PlaybackError)
    case ended
}
