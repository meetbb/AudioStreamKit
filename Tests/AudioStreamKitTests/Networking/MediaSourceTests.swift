//
//  MediaSourceTests.swift
//  AudioStreamKitTests
//
//  Created by Meet Brahmbhatt on 13/09/26.
//

import XCTest
@testable import AudioStreamKit

/// Scoped to what's testable without a live network or a real
/// `AVAssetResourceLoadingRequest` (which has no public initializer and can only be
/// obtained from AVFoundation actually driving asset loading). Full `contentInformationRequest`
/// / `dataRequest` / retry-loop behavior needs integration-style tests against a local HTTP
/// server — deferred, see `Documentation/CURRENT_STATE.md`.
final class MediaSourceTests: XCTestCase {

    // MARK: - Scheme rewriting

    func test_rewriteToCustomScheme_https_becomesAstkHttps() {
        let url = URL(string: "https://example.com/track.mp3")!
        XCTAssertEqual(MediaSource.rewriteToCustomScheme(url)?.absoluteString, "astk-https://example.com/track.mp3")
    }

    func test_rewriteToCustomScheme_http_becomesAstkHttp() {
        let url = URL(string: "http://example.com/track.mp3")!
        XCTAssertEqual(MediaSource.rewriteToCustomScheme(url)?.absoluteString, "astk-http://example.com/track.mp3")
    }

    func test_rewriteToCustomScheme_unsupportedScheme_returnsNil() {
        let url = URL(string: "file:///track.mp3")!
        XCTAssertNil(MediaSource.rewriteToCustomScheme(url))
    }

    func test_rewriteToRealScheme_astkHttps_becomesHttps() {
        let url = URL(string: "astk-https://example.com/track.mp3")!
        XCTAssertEqual(MediaSource.rewriteToRealScheme(url)?.absoluteString, "https://example.com/track.mp3")
    }

    func test_rewriteToRealScheme_astkHttp_becomesHttp() {
        let url = URL(string: "astk-http://example.com/track.mp3")!
        XCTAssertEqual(MediaSource.rewriteToRealScheme(url)?.absoluteString, "http://example.com/track.mp3")
    }

    func test_rewriteToRealScheme_unrecognizedScheme_returnsNil() {
        let url = URL(string: "https://example.com/track.mp3")!
        XCTAssertNil(MediaSource.rewriteToRealScheme(url))
    }

    func test_schemeRewriting_roundTrips() {
        let original = URL(string: "https://example.com/path/track.mp3?token=abc")!
        let rewritten = MediaSource.rewriteToCustomScheme(original)!
        XCTAssertEqual(MediaSource.rewriteToRealScheme(rewritten), original)
    }

    // MARK: - makeAsset

    func test_makeAsset_unsupportedScheme_throwsInvalidURL() {
        let source = MediaSource()
        let url = URL(string: "ftp://example.com/track.mp3")!
        XCTAssertThrowsError(try source.makeAsset(for: url)) { error in
            XCTAssertEqual(error as? PlaybackError, .invalidURL)
        }
    }

    func test_makeAsset_supportedScheme_producesRewrittenAssetURL() throws {
        let source = MediaSource()
        let url = URL(string: "https://example.com/track.mp3")!
        let asset = try source.makeAsset(for: url)
        XCTAssertEqual(asset.url.absoluteString, "astk-https://example.com/track.mp3")
    }

    // MARK: - cancelAll

    func test_cancelAll_withNoTrackedRequests_doesNotCrash() {
        let source = MediaSource()
        source.cancelAll()
    }

    // MARK: - segments(of:missing:)

    func test_segments_noGaps_isSinglePresentSegment() {
        XCTAssertEqual(MediaSource.segments(of: 0..<100, missing: []), [.present(0..<100)])
    }

    func test_segments_entireRangeMissing_isSingleMissingSegment() {
        XCTAssertEqual(MediaSource.segments(of: 0..<100, missing: [0..<100]), [.missing(0..<100)])
    }

    func test_segments_gapInMiddle_alternatesPresentMissingPresent() {
        let segments = MediaSource.segments(of: 0..<100, missing: [40..<60])
        XCTAssertEqual(segments, [.present(0..<40), .missing(40..<60), .present(60..<100)])
    }

    func test_segments_gapAtStart_hasNoLeadingPresentSegment() {
        let segments = MediaSource.segments(of: 0..<100, missing: [0..<20])
        XCTAssertEqual(segments, [.missing(0..<20), .present(20..<100)])
    }

    func test_segments_gapAtEnd_hasNoTrailingPresentSegment() {
        let segments = MediaSource.segments(of: 0..<100, missing: [80..<100])
        XCTAssertEqual(segments, [.present(0..<80), .missing(80..<100)])
    }

    func test_segments_multipleGaps_areOrderedAscending() {
        let segments = MediaSource.segments(of: 0..<100, missing: [60..<80, 10..<20])
        XCTAssertEqual(segments, [
            .present(0..<10), .missing(10..<20), .present(20..<60), .missing(60..<80), .present(80..<100)
        ])
    }
}
