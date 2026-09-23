# Getting to know AudioStreamKit

A framework walkthrough, written as questions you'd naturally ask
while reading the code for the first time.

## What is this project, at a high level?

AudioStreamKit is a Swift framework (a library, not an app) that handles
audio streaming on iOS: playing audio from a URL, caching what's been
downloaded so it doesn't have to be re-fetched, retrying when the network
hiccups, and reporting playback status. A separate iOS app is expected to
import this framework and use it — the framework itself has no UI.

## How do the pieces fit together?

Think of it as layers, each one only talking to the layer directly below it:

```
Your app
   |
AudioPlayer          <- the only thing your app talks to
   |
PlaybackEngine        <- the "brain": drives AVPlayer, tracks state
   |            \
PlaybackStateMachine   MediaSource   <- what state are we in? / where do bytes come from?
                          |
                       MediaCache      <- have we already downloaded this?
                          |
                       RetryPolicy + FailureClassifier   <- network retries & error classification
```

- **`AudioPlayer`** is the public front door. It's an `actor`, which is
  Swift's way of saying "only one piece of code can touch this at a time" —
  that matters because playback commands could otherwise come from multiple
  threads at once (a UI tap and a remote-control-center tap, for example)
  and step on each other.
- **`PlaybackEngine`** is where the real work happens. It owns Apple's
  `AVPlayer` and translates play/pause/seek calls into changes to the state
  machine, and vice versa.
- **`PlaybackStateMachine`** just tracks "what state is playback in right
  now" (idle, loading, playing, paused, buffering, failed, etc.) and which
  transitions are legal. It doesn't know anything about networking or
  `AVPlayer`.
- **`MediaSource`** decides where audio bytes come from: the cache if we
  have them, the network if we don't.
- **`MediaCache`** stores downloaded audio on disk so it isn't re-downloaded.
- **`RetryPolicy`** and **`FailureClassifier`** work together: when a
  network call fails, `FailureClassifier` decides *what kind* of failure it
  was (worth retrying? permanent?), and `RetryPolicy` decides *how* to
  retry (how many attempts, how long to wait between them).

## Why is `PlaybackStateMachine` separate from `PlaybackEngine`?

Because they have different jobs. The state machine's only job is "given
the current state and this event, what's the new state, and is this
transition even allowed?" It has no idea an `AVPlayer` exists. `PlaybackEngine`
is the one that talks to `AVPlayer`, and then reports what happened to the
state machine. Splitting them like this means you can test all the
state-transition rules without ever touching real playback, and you can
change how the real player works without touching the state rules.

## What does "one funnel" mean in `PlaybackEngine`?

`PlaybackEngine` listens to several different sources of truth about what's
happening: `AVPlayer`'s own status changes (KVO), notifications like "track
finished" or "phone call interrupted playback", and its own network layer
telling it about stalls or retries running out. All of these get funneled
through a single method, `apply(_:)`, instead of each source updating state
on its own. This means there's exactly one place where "here's what just
happened, here's the new state" logic lives, so you don't get two different
code paths disagreeing about what state we're in.

## Why is `AudioPlayer` an `actor`?

Because playback can be controlled from more than one place at the same
time — your app's UI, and also the iOS lock-screen / control-center remote
commands (play/pause/skip buttons that show up outside your app). If two
of those fired at once without protection, you could get race conditions
(e.g. both trying to change state at the same moment, leaving things
inconsistent). Making `AudioPlayer` an actor means Swift enforces that only
one command runs at a time.

## How does caching decide whether to hit the network?

`MediaSource` checks `MediaCache` first. If the requested byte range is
already cached, it's served straight from disk — no network call. If it's
partially cached, only the missing range is fetched. If nothing is cached,
it fetches from the network and writes what it downloaded into the cache
for next time. There's also a lightweight check ("has this file changed
since we cached it?") using HTTP validators (ETag / Last-Modified), so a
cache hit isn't blindly trusted forever — but if the network call to check
freshness fails, the existing cached copy is used anyway rather than
failing playback.

## What happens when a network request fails?

1. `FailureClassifier` looks at the error and decides what kind of problem
   it is — a transient network issue (worth retrying), a permanent HTTP
   error (not worth retrying), or something with the audio file itself
   (can't be decoded, wrong format).
2. If it's retryable, `RetryPolicy` decides how many times to retry and
   how long to wait between attempts (with increasing delays, so it
   doesn't hammer the server).
3. If retries run out, `MediaSource` reports that upward so the app can be
   told "we gave up" instead of hanging forever.

## Why do audio session handling (interruptions, lock-screen controls) only exist on iOS?

Some Apple frameworks used here (`AVAudioSession`, the thing that manages
how your app's audio behaves alongside phone calls, other apps' audio,
etc.) only exist on iOS — they're not available if the same code is
compiled for macOS. Since this package is also built and tested on macOS
(for convenience during development), that iOS-only code has to be walled
off so the rest of the framework still compiles on a Mac. `MPNowPlayingInfoCenter`
and `MPRemoteCommandCenter` (lock-screen "Now Playing" info and remote
play/pause buttons) don't have this restriction, so they run and get
tested on macOS fine.

## Why does the audio session only get deactivated in `stop()`, not every time a track changes?

Deactivating the audio session hands audio control back to the system,
which can disrupt other apps that might be playing audio too. If you
deactivated it every single time a track changed (even to immediately
play the next track), you'd be needlessly interrupting things. It's only
deactivated when playback is truly done (`stop()`), not between tracks.

## What's the general rule for when something needs a design discussion vs. just fixing it directly?

Small stuff — bug fixes, adding tests, internal cleanup that doesn't
change behavior — gets done directly. Anything that touches a public API,
adds a new file/type, or is a real architectural decision (e.g. changing
retry behavior, changing what a public method does) is treated as bigger:
it gets explained in a few sentences before being implemented, so there's
a chance to catch a bad direction before code gets written, not after.

## A simple mental model to hold onto

- **State machine** = "what state are we in, and what's allowed next?"
- **Engine** = "translate real-world events (player, network, phone calls)
  into state changes, and drive the real player."
- **Source + Cache** = "get me these bytes, from disk if possible,
  network if not."
- **Retry + Classifier** = "was that failure worth retrying, and how?"
- **AudioPlayer** = "the one door your app knocks on, safely, from any
  thread."
