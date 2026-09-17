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

    /// Checks that temporary network problems (like a dropped connection) are marked as worth
    /// retrying.
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

    /// Checks that a broken or unsupported web address is marked as a dead end, not something
    /// worth retrying.
    func test_malformedURLErrors_areTerminal_notRetried() {
        for code: URLError.Code in [.badURL, .unsupportedURL] {
            let urlError = URLError(code)
            let result = FailureClassifier.classify(urlError)
            XCTAssertEqual(result, .terminal(.invalidURL), "code: \(code)")
        }
    }

    /// Checks that an unfamiliar network error safely defaults to "don't retry," instead of
    /// accidentally retrying forever.
    func test_unrecognizedURLError_defaultsToTerminal() {
        let urlError = URLError(.dataNotAllowed)
        let result = FailureClassifier.classify(urlError)
        XCTAssertEqual(result, .terminal(.network(urlError)))
    }

    // MARK: - Retry behaviour: HTTP status codes

    /// Checks that server error codes which are usually temporary (like a timeout or an
    /// overloaded server) are marked as worth retrying.
    func test_retryableHTTPStatusCodes() {
        for statusCode in [408, 429, 500, 503, 599] {
            let error = HTTPStatusError(statusCode: statusCode)
            let result = FailureClassifier.classify(error)
            XCTAssertEqual(result, .retryable(.http(statusCode: statusCode)), "status: \(statusCode)")
        }
    }

    /// Checks that error codes which won't be fixed by retrying (like "not found" or
    /// "unauthorized") are correctly marked as dead ends.
    func test_terminalHTTPStatusCodes() {
        for statusCode in [400, 401, 404, 407, 499, 600] {
            let error = HTTPStatusError(statusCode: statusCode)
            let result = FailureClassifier.classify(error)
            XCTAssertEqual(result, .terminal(.http(statusCode: statusCode)), "status: \(statusCode)")
        }
    }

    // MARK: - Failure paths: asset-layer / unrecognized errors

    private struct SomeUnrelatedError: Error {}

    /// Checks that a completely unknown kind of error still gets a sensible fallback
    /// classification, instead of crashing or being ignored.
    func test_unrecognizedErrorType_classifiesAsTerminalDecodeFailed() {
        let result = FailureClassifier.classify(SomeUnrelatedError())
        XCTAssertEqual(result, .terminal(.decodeFailed))
    }

    /// Checks that the original playback error can always be pulled back out of a
    /// classification result.
    func test_classification_exposesUnderlyingPlaybackError() {
        let result = FailureClassifier.classify(URLError(.timedOut))
        XCTAssertEqual(result.playbackError, .network(URLError(.timedOut)))
    }

    // MARK: - Cancellation

    /// Checks that a request the app itself cancelled is never mistakenly retried.
    func test_cancelledURLError_isClassifiedAsTerminal_notRetried() {
        let urlError = URLError(.cancelled)
        let result = FailureClassifier.classify(urlError)
        XCTAssertEqual(result, .terminal(.network(urlError)))
    }

    /// Documents a known gap: a generic cancellation error isn't specially recognized yet, so
    /// it falls back to the same generic classification as any unknown error.
    func test_cancellationError_fallsToAssetLayerDefault() {
        let result = FailureClassifier.classify(CancellationError())
        XCTAssertEqual(result, .terminal(.decodeFailed))
    }
}
