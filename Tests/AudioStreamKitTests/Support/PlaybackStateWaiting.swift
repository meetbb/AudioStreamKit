//
//  PlaybackStateWaiting.swift
//  AudioStreamKitTests
//

import XCTest
@testable import AudioStreamKit

/// Records states off an `AsyncStream<PlaybackState>` as they arrive. `actor`-isolated purely so
/// the consuming `Task` in `XCTestCase.collectStates` and the asserting test body can share it
/// safely — `PlaybackState` itself is `Sendable`, so nothing trickier than that is needed.
actor PlaybackStateRecorder {
    private(set) var states: [PlaybackState] = []

    func record(_ state: PlaybackState) {
        states.append(state)
    }
}

extension XCTestCase {
    /// Consumes `stream` until a state matching `predicate` arrives (inclusive) or `timeout`
    /// elapses, and returns every state observed in order. Fails the test if the predicate never
    /// matches in time, rather than hanging indefinitely — real network/asset resolution over
    /// loopback is fast, so a timeout here means an actual bug in the state transition, not
    /// slowness.
    func collectStates(
        from stream: AsyncStream<PlaybackState>,
        until predicate: @escaping @Sendable (PlaybackState) -> Bool,
        timeout: TimeInterval = 5
    ) async -> [PlaybackState] {
        let recorder = PlaybackStateRecorder()
        let expectation = expectation(description: "state matching predicate")
        let task = Task {
            for await state in stream {
                await recorder.record(state)
                if predicate(state) {
                    expectation.fulfill()
                    break
                }
            }
        }
        await fulfillment(of: [expectation], timeout: timeout)
        task.cancel()
        return await recorder.states
    }
}
