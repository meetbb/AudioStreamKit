//
//  FailureClassifierTests.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import XCTest
@testable import AudioStreamKit

// Applicable categories for this component:
// - Failure paths (this type's entire job is classifying failures)
// - Network interruption (URLError codes that represent a dropped/lost
//   connection must classify as retryable)
// - Retry behaviour (the retryable/terminal boundary for both URLError
//   codes and HTTP status codes)
// - Cancellation (how a cancelled request/task is currently classified —
//   documents existing behavior, including a known gap; see note below)
//
// Not applicable — intentionally skipped:
// - Success paths: there's no "success" input to a failure classifier;
//   correctness is fully covered by the retryable/terminal assertions
//   below for each input family.
// - Concurrency: `FailureClassifier` is a stateless enum of static pure
//   functions — there is no shared state for concurrent calls to race on.
// - Cache behaviour / State transitions / Resource cleanup: not
//   applicable to a stateless classification function.
final class FailureClassifierTests: XCTestCase {

    // MARK: - Network interruption / retry behaviour: URLError codes

    func test_transientNetworkErrors_areRetryable() {
        let retryableCodes: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .cannotConnectToHost,
            .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost
        ]
        for code in retryableCodes {
            let urlError = URLError(code)
            let result = FailureClassifier.classify(urlError)
            XCTAssertEqual(result, .retryable(.network(urlError)), "code: \(code)")
        }
    }

    func test_malformedURLErrors_areTerminal_notRetried() {
        for code: URLError.Code in [.badURL, .unsupportedURL] {
            let urlError = URLError(code)
            let result = FailureClassifier.classify(urlError)
            XCTAssertEqual(result, .terminal(.invalidURL), "code: \(code)")
        }
    }

    func test_unrecognizedURLError_defaultsToTerminal() {
        // Any URLError code not explicitly listed as retryable falls back
        // to terminal rather than being silently retried forever.
        let urlError = URLError(.dataNotAllowed)
        let result = FailureClassifier.classify(urlError)
        XCTAssertEqual(result, .terminal(.network(urlError)))
    }

    // MARK: - Retry behaviour: HTTP status codes

    func test_retryableHTTPStatusCodes() {
        for statusCode in [408, 429, 500, 503, 599] {
            let error = HTTPStatusError(statusCode: statusCode)
            let result = FailureClassifier.classify(error)
            XCTAssertEqual(result, .retryable(.http(statusCode: statusCode)), "status: \(statusCode)")
        }
    }

    func test_terminalHTTPStatusCodes() {
        for statusCode in [400, 401, 404, 407, 499, 600] {
            let error = HTTPStatusError(statusCode: statusCode)
            let result = FailureClassifier.classify(error)
            XCTAssertEqual(result, .terminal(.http(statusCode: statusCode)), "status: \(statusCode)")
        }
    }

    // MARK: - Failure paths: asset-layer / unrecognized errors

    private struct SomeUnrelatedError: Error {}

    func test_unrecognizedErrorType_classifiesAsTerminalDecodeFailed() {
        let result = FailureClassifier.classify(SomeUnrelatedError())
        XCTAssertEqual(result, .terminal(.decodeFailed))
    }

    func test_classification_exposesUnderlyingPlaybackError() {
        let result = FailureClassifier.classify(URLError(.timedOut))
        XCTAssertEqual(result.playbackError, .network(URLError(.timedOut)))
    }

    // MARK: - Cancellation

    func test_cancelledURLError_isClassifiedAsTerminal_notRetried() {
        // URLError.cancelled isn't in the retryable list, so it falls to
        // the "any other URLError" default of terminal — a cancelled
        // request must never be retried.
        let urlError = URLError(.cancelled)
        let result = FailureClassifier.classify(urlError)
        XCTAssertEqual(result, .terminal(.network(urlError)))
    }

    func test_cancellationError_fallsToAssetLayerDefault() {
        // Documents current behavior rather than an intentional design:
        // a plain CancellationError isn't URLError/HTTPStatusError, so it
        // falls into the asset-layer catch-all and comes back as
        // .terminal(.decodeFailed) — the same placeholder classification
        // used for every unrecognized error (see FailureClassifier's
        // `classifyAsset`, which doesn't yet inspect real AVFoundation
        // error codes). Flagged, not fixed, per this command's scope.
        let result = FailureClassifier.classify(CancellationError())
        XCTAssertEqual(result, .terminal(.decodeFailed))
    }
}
