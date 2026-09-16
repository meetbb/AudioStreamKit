//
//  FailureClassifier.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation

/// `.retryable`/`.terminal` both carry the PlaybackError payload so the same classification is reusable both to
/// decide the tier *and*, unchanged, as the payload if a retryable failure later exhausts its budget – no separate exhaustion-specific mapping.
enum FailureClassification: Equatable {
    case retryable(PlaybackError)
    case terminal(PlaybackError)
    
    var playbackError: PlaybackError {
        switch self {
            case .retryable(let error), .terminal(let error):
                return error
        }
    }
}

/// A raw HTTP failure response (non-2xx). `FailureClassifier` has no
/// `URLSession`/networking dependency of its own — whatever issued the
/// request constructs this from the response it got back.
struct HTTPStatusError: Error, Sendable, Equatable {
    let statusCode: Int
}

enum FailureClassifier {

    static func classify(_ error: Error) -> FailureClassification {
        if let urlError = error as? URLError {
            return classifyNetwork(urlError)
        }
        if let httpError = error as? HTTPStatusError {
            return classifyHTTP(httpError.statusCode)
        }
        // Anything else (e.g. an AVFoundation asset-loading failure) is always
        // terminal — the asset layer has no retryable branch.
        return .terminal(classifyAsset(error))
    }

    // MARK: - Network layer
    private static func classifyNetwork(_ urlError: URLError) -> FailureClassification {
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost:
            return .retryable(.network(urlError))
        case .badURL, .unsupportedURL:
            return .terminal(.invalidURL)
        default:
            return .terminal(.network(urlError))
        }
    }

    // MARK: - HTTP layer
    private static func classifyHTTP(_ statusCode: Int) -> FailureClassification {
        switch statusCode {
        case 408, 429, 500...599:
            return .retryable(.http(statusCode: statusCode))
        default:
            return .terminal(.http(statusCode: statusCode))
        }
    }

    // MARK: - Asset layer
    private static func classifyAsset(_ error: Error) -> PlaybackError {
        // Deliberately not distinguishing .decodeFailed from .unsupportedFormat by inspecting
        // real AVError codes yet, and no dedicated .cancelled case — see
        // Documentation/CURRENT_STATE.md's known limitations. Defaulting to .decodeFailed until
        // this is revisited.
        .decodeFailed
    }
}
