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

    /// Checks that a secure web address gets tagged as ours internally, so we can always
    /// intercept and handle its network requests ourselves.
    func test_rewriteToCustomScheme_https_becomesAstkHttps() {
        let url = URL(string: "https://example.com/track.mp3")!
        XCTAssertEqual(MediaSource.rewriteToCustomScheme(url)?.absoluteString, "astk-https://example.com/track.mp3")
    }

    /// Checks that a regular (non-secure) web address gets tagged as ours internally too.
    func test_rewriteToCustomScheme_http_becomesAstkHttp() {
        let url = URL(string: "http://example.com/track.mp3")!
        XCTAssertEqual(MediaSource.rewriteToCustomScheme(url)?.absoluteString, "astk-http://example.com/track.mp3")
    }

    /// Checks that an address we don't support (like a local file) is rejected instead of
    /// silently accepted.
    func test_rewriteToCustomScheme_unsupportedScheme_returnsNil() {
        let url = URL(string: "file:///track.mp3")!
        XCTAssertNil(MediaSource.rewriteToCustomScheme(url))
    }

    /// Checks that a secure address tagged as ours can be converted back to its original form.
    func test_rewriteToRealScheme_astkHttps_becomesHttps() {
        let url = URL(string: "astk-https://example.com/track.mp3")!
        XCTAssertEqual(MediaSource.rewriteToRealScheme(url)?.absoluteString, "https://example.com/track.mp3")
    }

    /// Checks that a regular address tagged as ours can be converted back to its original form.
    func test_rewriteToRealScheme_astkHttp_becomesHttp() {
        let url = URL(string: "astk-http://example.com/track.mp3")!
        XCTAssertEqual(MediaSource.rewriteToRealScheme(url)?.absoluteString, "http://example.com/track.mp3")
    }

    /// Checks that an address that was never tagged as ours is rejected when asked to convert
    /// it back.
    func test_rewriteToRealScheme_unrecognizedScheme_returnsNil() {
        let url = URL(string: "https://example.com/track.mp3")!
        XCTAssertNil(MediaSource.rewriteToRealScheme(url))
    }

    /// Checks that tagging an address as ours and then converting it back gives the exact same
    /// address we started with.
    func test_schemeRewriting_roundTrips() {
        let original = URL(string: "https://example.com/path/track.mp3?token=abc")!
        let rewritten = MediaSource.rewriteToCustomScheme(original)!
        XCTAssertEqual(MediaSource.rewriteToRealScheme(rewritten), original)
    }

    // MARK: - makeAsset

    /// Checks that trying to play from an unsupported address fails right away with a clear
    /// error, instead of trying and failing later.
    func test_makeAsset_unsupportedScheme_throwsInvalidURL() {
        let source = MediaSource()
        let url = URL(string: "ftp://example.com/track.mp3")!
        XCTAssertThrowsError(try source.makeAsset(for: url)) { error in
            XCTAssertEqual(error as? PlaybackError, .invalidURL)
        }
    }

    /// Checks that a supported address is correctly tagged as ours when preparing it for
    /// playback.
    func test_makeAsset_supportedScheme_producesRewrittenAssetURL() throws {
        let source = MediaSource()
        let url = URL(string: "https://example.com/track.mp3")!
        let asset = try source.makeAsset(for: url)
        XCTAssertEqual(asset.url.absoluteString, "astk-https://example.com/track.mp3")
    }

    // MARK: - cancelAll

    /// Checks that cancelling all requests is safe even when there's nothing to cancel.
    func test_cancelAll_withNoTrackedRequests_doesNotCrash() {
        let source = MediaSource()
        source.cancelAll()
    }

    // MARK: - segments(of:missing:)
    //
    // These tests check the logic that figures out which parts of a requested chunk of a
    // track are already downloaded ("present") versus still need fetching ("missing").

    /// Checks that a fully downloaded range is reported as one single present segment.
    func test_segments_noGaps_isSinglePresentSegment() {
        XCTAssertEqual(MediaSource.segments(of: 0..<100, missing: []), [.present(0..<100)])
    }

    /// Checks that a range with nothing downloaded yet is reported as one single missing
    /// segment.
    func test_segments_entireRangeMissing_isSingleMissingSegment() {
        XCTAssertEqual(MediaSource.segments(of: 0..<100, missing: [0..<100]), [.missing(0..<100)])
    }

    /// Checks that a gap in the middle of an otherwise downloaded range is split into three
    /// correct pieces: present, then missing, then present.
    func test_segments_gapInMiddle_alternatesPresentMissingPresent() {
        let segments = MediaSource.segments(of: 0..<100, missing: [40..<60])
        XCTAssertEqual(segments, [.present(0..<40), .missing(40..<60), .present(60..<100)])
    }

    /// Checks that a gap right at the start doesn't produce an empty leading present segment.
    func test_segments_gapAtStart_hasNoLeadingPresentSegment() {
        let segments = MediaSource.segments(of: 0..<100, missing: [0..<20])
        XCTAssertEqual(segments, [.missing(0..<20), .present(20..<100)])
    }

    /// Checks that a gap right at the end doesn't produce an empty trailing present segment.
    func test_segments_gapAtEnd_hasNoTrailingPresentSegment() {
        let segments = MediaSource.segments(of: 0..<100, missing: [80..<100])
        XCTAssertEqual(segments, [.present(0..<80), .missing(80..<100)])
    }

    /// Checks that several separate gaps are handled correctly and listed in the right order,
    /// even if they weren't given in order.
    func test_segments_multipleGaps_areOrderedAscending() {
        let segments = MediaSource.segments(of: 0..<100, missing: [60..<80, 10..<20])
        XCTAssertEqual(segments, [
            .present(0..<10), .missing(10..<20), .present(20..<60), .missing(60..<80), .present(80..<100)
        ])
    }
}
