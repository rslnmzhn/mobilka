# Background behavior — iOS compliance design

Roadmap item 49. Companion to the Android Foreground Service (item 46).

## Platform reality

iOS grants roughly 30 seconds of grace after an app leaves the foreground
(`beginBackgroundTask`), then suspends the process. There is **no** supported
long-running streaming equivalent of Android's foreground service for third-
party chat apps. Any design that "keeps the stream alive" beyond that window
would violate App Store guidance.

## mobilka's contract

1. **No unrestricted-background promises.** The UI never claims that a request
   continues indefinitely once backgrounded; the interrupted-response model
   (`ChatMessageStatus.interrupted` + retry) is the documented recovery path.
2. **Optimistic durability before suspension.** Every stream delta persists to
   Hive immediately (streaming coordinator), and `AppLifecycleState.paused/
   hidden` triggers an extra flush of the active conversation (item 47). A
   suspended or killed process therefore loses at most the final delta.
3. **Foreground service stays Android-only.** `BackgroundTaskBridge` resolves
   to `AndroidForegroundTaskBridge` on Android and to a no-op everywhere else;
   iOS never starts background services, so nothing can be rejected for
   misuse of background modes.
4. **Retry is first-class.** Interrupted requests keep their user message and
   retry metadata; `retryInterrupted` rebuilds the request from persisted
   state without duplicating messages.
5. **Future options are additive, not behavioral promises:** silent push to
   wake the app, or BGTaskScheduler-style defers, may shorten perceived gaps,
   but the product copy must continue to say results require the app
   foregrounded or recently active.

## Enforcement points

| Layer | Guard |
|---|---|
| `background_task_bridge.dart` | platform switch returns the no-op bridge unless Android |
| `app.dart` | lifecycle flush on paused/hidden |
| Coordinator | transient retry only before first token; otherwise interrupted |
| UI copy | retry affordance framed as expected recovery, not a failure |
