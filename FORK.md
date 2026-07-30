# RustDesk BG

A fork of [RustDesk](https://github.com/rustdesk/rustdesk) that fixes the Android
client dropping its session the moment you leave the app.

Upstream RustDesk on Android, used as a **controller** (your phone driving a PC),
disconnects when you open the app switcher, reply in another app, or take a call.
This fork keeps the session alive.

It installs **alongside** a stock RustDesk rather than replacing it, so you can run
both and compare.

## The bug, and why it happens

When the Android app is the controller, nothing holds the process in the
foreground. `MainService` — the only foreground service upstream has — is
`mediaProjection`-typed and starts solely when the phone is the one being *shared*.

So the moment the app leaves the screen, the process drops into the cached bucket,
where Android's cached-app freezer `SIGSTOP`s every thread in it — including the
Rust tokio runtime driving the connection. The socket goes silent, the peer tears
the connection down, and on thaw the client's own 30-second no-data check fires
immediately, because monotonic time kept running throughout.

Nothing in the Dart lifecycle handlers or `MainActivity` closes the session. The
teardown is entirely below the app.

## What's changed

| Change | What it does |
| --- | --- |
| `SessionKeepAliveService` | A foreground service held for the life of a remote session, so the process is never cacheable. Partial wake + wifi locks cover screen-off and Doze. |
| Freeze-aware timeout | The no-data check now detects a process stall via the timer overshooting its own period, and grants another window instead of killing a healthy session. A genuinely dead peer still surfaces immediately. |
| Background video throttle | Off-screen sessions drop to 2 fps and restore on return, so a backgrounded session doesn't stream full-rate video into nothing. Throttled rather than stopped — the frames still arriving are what keep the timeout satisfied. |
| Separate application ID | `com.carriez.flutter_hbb.bg`, so it coexists with a stock install. |

The throttle deliberately triggers only on `paused`/`hidden`, never `inactive`: a
visible-but-unfocused window — an OEM floating/freeform window, or the notification
shade pulled down — reports `inactive`, and throttling that would stutter a window
you are looking straight at.

Only the `applicationId` moves. The Kotlin package stays `com.carriez.flutter_hbb`,
because the Rust side resolves Kotlin classes by JNI path and the generated `R`
class lives there.

## Installing

Because the application ID differs, this is a **separate app** with its own private
data directory. It starts with a fresh RustDesk ID and no saved peers — you'll enter
your PC's ID and password once. Your existing RustDesk install is untouched.

A persistent "Remote session active" notification appears while connected. That
notification *is* the fix — if it disappears while you're still connected, the
keep-alive has failed.

### If sessions still drop

Aggressive OEM power management (Samsung, Xiaomi, OnePlus and similar) can kill
even a foreground service. Exempt the app from battery optimisation in system
settings.

## Versions

Builds are versioned `<upstream>-bg.<build>+<commit>`, e.g. `1.4.9-bg.4+5aec1e9`,
shown in Settings → About. The commit is resolved from git at build time, so any
installed build traces back to the source that produced it.

## Building

Android builds run in CI — there is no supported native-Windows path, since the
native dependencies are built by `flutter/build_android_deps.sh`, which needs a
Linux host with the NDK. Trigger the `Flutter Nightly Build` workflow; the Android
job only depends on `generate-bridge`, so other platforms failing doesn't matter.

## Upstream

The two behavioural fixes (keep-alive and throttle) are not fork-specific and
belong upstream — they're kept on a separate branch free of the branding and
app-ID changes, which must not go up.

## Licence

RustDesk is AGPL-3.0, and so is this fork; see [LICENCE](LICENCE). Source for these
modifications is this repository.

RustDesk's name and logo belong to the upstream project. This fork keeps both,
recoloured — it is not an official RustDesk release and is not endorsed by them.
