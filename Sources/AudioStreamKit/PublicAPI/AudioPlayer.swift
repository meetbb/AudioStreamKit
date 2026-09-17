//
//  AudioPlayer.swift
//  AudioStreamKit
//
//  Created by Meet Brahmbhatt on 11/09/26.
//

import Foundation

/// The public facade for AudioStreamKit — see `Documentation/architecture/public-api.md` §3.
/// Every method delegates straight to `PlaybackEngine`; all real playback logic, AVFoundation
/// usage, and state live there. `AudioPlayer` itself only owns the `AsyncStream` boundary and
/// wires `CacheConfiguration` into `MediaCache`/`MediaSource` at construction.
public actor AudioPlayer {

    private let engine: PlaybackEngine

    /// The only `AsyncStream` in the framework (`concurrency-model.md` §4) — `AudioPlayer`
    /// creates it and keeps the continuation, `PlaybackEngine` `yield`s into that continuation
    /// directly after every state transition. No forwarding `Task` needed.
    public nonisolated let states: AsyncStream<PlaybackState>
    private let stateContinuation: AsyncStream<PlaybackState>.Continuation

    public init(cacheConfiguration: CacheConfiguration = .default) {
        var continuation: AsyncStream<PlaybackState>.Continuation!
        self.states = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation

        let mediaCache = MediaCache(configuration: cacheConfiguration)
        let mediaSource = MediaSource(mediaCache: mediaCache)
        self.engine = PlaybackEngine(stateSink: continuation, mediaSource: mediaSource)
    }

    /// Test-only seam (not exposed publicly — `public-api.md` §7 already rejected a public
    /// protocol for mocking). Lets tests supply a `PlaybackEngine` built around a test
    /// `MediaSource`/local server, so `AudioPlayer`'s delegation and `AsyncStream` wiring can be
    /// verified without going through the public init's real `MediaCache`/`MediaSource` stack.
    /// `states`/`stateContinuation` must be the same stream `engine` was constructed with
    /// (`PlaybackEngine(stateSink:mediaSource:)` takes the continuation at init).
    init(
        states: AsyncStream<PlaybackState>,
        stateContinuation: AsyncStream<PlaybackState>.Continuation,
        engine: PlaybackEngine
    ) {
        self.states = states
        self.stateContinuation = stateContinuation
        self.engine = engine
    }

    /// Finishes `states` so a consumer's `for await` loop terminates if this instance is
    /// deallocated without an explicit `stop()` first.
    deinit {
        stateContinuation.finish()
    }

    public func load(_ item: MediaItem) async {
        await engine.load(item)
    }

    public func play() async {
        await engine.play()
    }

    public func pause() async {
        await engine.pause()
    }

    public func stop() async {
        await engine.stop()
    }

    public func seek(to time: TimeInterval) async {
        await engine.seek(to: time)
    }

    public var currentTime: TimeInterval {
        get async { await engine.currentTime }
    }

    public var duration: TimeInterval? {
        get async { await engine.duration }
    }
}
