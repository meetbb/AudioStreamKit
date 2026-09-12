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
        }
    }
}
