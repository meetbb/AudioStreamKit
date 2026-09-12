//
//  PlaybackState.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation

enum PlaybackState: Equatable {
    case idle
    case loading
    case buffering
    case playing
    case paused
    case stalled
    case failed(PlaybackError)
    case ended
}
