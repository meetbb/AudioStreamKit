//
//  PlaybackEvent.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation

enum PlaybackEvent {
    // Commands – from AudioPlayer's public API
    case loadRequested
    case playRequested
    case pauseRequested
    case stopRequested
    case seekRequested
    
    // Engine-reported – from AVFoundation/MediaSource
    case itemReady
    case bufferingBegan
    case bufferingEnded // buffer sufficient; audio is flowing
    case networkStallBegan
    case networkStallRecovered
    case retryBudgetExhausted(PlaybackError)
    case itemFailed(PlaybackError)
    case itemEnded
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
}
