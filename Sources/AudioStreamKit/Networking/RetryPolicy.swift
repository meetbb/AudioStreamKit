//
//  RetryPolicy.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation

/// Stateless exponential-backoff calculator. It does not track attempt counts itself –
/// the caller (`MediaSource`) owns the counter and asks this for a delay/budget
/// check at each attempt.
struct RetryPolicy: Sendable, Equatable {
    
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    
    // Placeholder values explicitly defers exact backoff parameters
    // as implementation detail. Tune these once real network behavior
    // is observed; not derived from any requirement.
    static let `default` = RetryPolicy(maxAttempts: 5, baseDelay: 0.5, maxDelay: 16)
    
    /// `attempt` is 1-based: the delay to wait before making this attempt.
    func delay(forAttempt attempt: Int) -> TimeInterval {
        precondition(attempt >= 1, "attempt is 1-based")
        let exponential = baseDelay * pow(2, Double(attempt - 1))
        return min(exponential, maxDelay)
    }
    
    /// Whether `attempt` is still within the retry budget.
    func hasBudget(forAttempt attempt: Int) -> Bool {
        attempt <= maxAttempts
    }
}
