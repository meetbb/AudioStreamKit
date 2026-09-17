//
//  RetryPolicyTests.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import XCTest
@testable import AudioStreamKit

// Applicable categories for this component:
// - Success paths (correct backoff delay for normal attempt numbers)
// - Retry behaviour (budget boundary via hasBudget(forAttempt:))
// - Concurrency (it's a stateless Sendable struct — verify it produces
//   consistent results when called concurrently from multiple tasks,
//   since that's the whole point of it being stateless/Sendable)
//
// Not applicable — intentionally skipped:
// - Failure paths / Cancellation: `RetryPolicy` doesn't throw or fail; its
//   only precondition (`attempt >= 1`) is a programmer-error trap, not a
//   recoverable failure path, and isn't practical to test without a
//   crash-testing harness.
// - Network interruption: this type has no network dependency — it only
//   computes a delay number. `FailureClassifier` is what reacts to actual
//   network failures.
// - Cache behaviour / State transitions / Resource cleanup: not
//   applicable to a stateless pure-calculation struct.
final class RetryPolicyTests: XCTestCase {

    // MARK: - Success paths: backoff calculation

    /// Checks that with the default settings, the wait time before each retry doubles each
    /// time, as expected.
    func test_defaultPolicy_delayDoublesPerAttempt_untilCapped() {
        let policy = RetryPolicy.default // maxAttempts: 5, baseDelay: 0.5, maxDelay: 16

        XCTAssertEqual(policy.delay(forAttempt: 1), 0.5)
        XCTAssertEqual(policy.delay(forAttempt: 2), 1.0)
        XCTAssertEqual(policy.delay(forAttempt: 3), 2.0)
        XCTAssertEqual(policy.delay(forAttempt: 4), 4.0)
        XCTAssertEqual(policy.delay(forAttempt: 5), 8.0)
    }

    /// Checks that the wait time between retries never grows past its maximum, even after many
    /// attempts.
    func test_delay_isCappedAtMaxDelay_evenBeyondMaxAttempts() {
        let policy = RetryPolicy.default

        // Uncapped exponential would be 16 and 32; both must clamp to 16.
        XCTAssertEqual(policy.delay(forAttempt: 6), 16.0)
        XCTAssertEqual(policy.delay(forAttempt: 7), 16.0)
    }

    /// Checks that custom retry settings (not just the defaults) are actually respected when
    /// calculating wait times.
    func test_customPolicy_respectsItsOwnParameters() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1.0, maxDelay: 2.0)

        XCTAssertEqual(policy.delay(forAttempt: 1), 1.0)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2.0) // exactly at the cap
        XCTAssertEqual(policy.delay(forAttempt: 3), 2.0) // would be 4.0 uncapped
    }

    // MARK: - Retry behaviour: budget boundary

    /// Checks that retries are allowed up to the maximum attempt count, and correctly refused
    /// right after that.
    func test_hasBudget_trueWithinMaxAttempts_falseBeyond() {
        let policy = RetryPolicy.default // maxAttempts: 5

        XCTAssertTrue(policy.hasBudget(forAttempt: 1))
        XCTAssertTrue(policy.hasBudget(forAttempt: 5))
        XCTAssertFalse(policy.hasBudget(forAttempt: 6))
    }

    /// Checks that a custom retry limit (like allowing only one attempt) is respected.
    func test_hasBudget_withCustomMaxAttempts() {
        let policy = RetryPolicy(maxAttempts: 1, baseDelay: 0.1, maxDelay: 1.0)

        XCTAssertTrue(policy.hasBudget(forAttempt: 1))
        XCTAssertFalse(policy.hasBudget(forAttempt: 2))
    }

    // MARK: - Concurrency

    /// Checks that asking for the same wait time from many places at once always gives the
    /// same, correct answer — nothing gets mixed up.
    func test_delay_isConsistentWhenCalledConcurrently() async {
        let policy = RetryPolicy.default

        await withTaskGroup(of: (Int, TimeInterval).self) { group in
            for attempt in 1...5 {
                for _ in 0..<20 {
                    group.addTask { (attempt, policy.delay(forAttempt: attempt)) }
                }
            }
            for await (attempt, delay) in group {
                XCTAssertEqual(delay, policy.delay(forAttempt: attempt))
            }
        }
    }
}
