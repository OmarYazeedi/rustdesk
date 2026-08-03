# IHPortals

A fork of [RustDesk](https://github.com/rustdesk/rustdesk) carrying two features
upstream doesn't have:

- **Android sessions survive being backgrounded.** Upstream's Android client, used
  as a *controller*, drops its session when you open the app switcher, reply in
  another app, or take a call.
- **Windows works as a touch device.** Tablet mode gives the desktop client the
  touch affordances the mobile clients have: a switchable touch/mouse mode, pinch
  zoom, finger-sized chrome, and on-screen keyboards.

It installs **alongside** a stock RustDesk rather than replacing it — separate
config dir, separate device ID, separate service name and IPC pipe — so you can
run both.

## What's changed

### Android

| Change | What it does |
| --- | --- |
| `SessionKeepAliveService` | A foreground service held for the life of a remote session, so the process is never cacheable. Partial wake + wifi locks cover screen-off and Doze. Off via **Settings → Keep session alive in background**, which costs a persistent notification. |
| Freeze-aware timeout | The no-data check detects a process stall via the timer overshooting its own period, and grants another window instead of killing a healthy session. A genuinely dead peer still surfaces immediately. |
| Background video throttle | Off-screen sessions drop to 2 fps and restore on return. Throttled rather than stopped — the frames still arriving are what keep the timeout satisfied. |

The throttle deliberately triggers only on `paused`/`hidden`, never `inactive`: a
visible-but-unfocused window — an OEM floating/freeform window, or the notification
shade pulled down — reports `inactive`, and throttling that would stutter a window
you are looking straight at.

### Windows

| Change | What it does |
| --- | --- |
| Tablet mode | Desktop honours the touch/mouse mode switch instead of pinning touch mode, which left the trackpad-style cursor unreachable. Off by default; nothing changes until it's on. |
| Pinch zoom | Two fingers zoom and pan the local view rather than forwarding the gesture to the peer. |
| Touch-sized chrome | Toolbar buttons, menu rows and the collapse handle grow to 46px in tablet mode. |
| Keyboards | The Windows touch keyboard (TabTip, via `ITipInvocation`), the accessibility On-Screen Keyboard, and an in-app keyboard as last resort. A draggable floating button and a fixed toolbar toggle raise whichever works. |

### Identity

`APP_NAME` is set to `IHPortals`, which drives the `%APPDATA%` config dir, the IPC
pipe name, the Windows service name and the install paths. On Android only the
`applicationId` moves (`com.ihportals.app`) — the Kotlin package stays
`com.carriez.flutter_hbb`, because the Rust side resolves Kotlin classes by JNI
path and the generated `R` class lives there.

---

## Keeping up with upstream

This is the part that decides whether the fork stays alive. RustDesk is
remote-access software: falling months behind upstream means carrying known
security holes, so syncing matters more here than on an ordinary fork.

### How the changes are arranged to make this cheap

1. **New behaviour lives in new files.** `soft_keyboard.dart`,
   `floating_keyboard_button.dart`, `windows_touch_keyboard.dart` and
   `SessionKeepAliveService.kt` are ours alone — upstream doesn't know they exist,
   so they can never conflict.
2. **Edits to upstream files are flag-gated and narrow.** Almost everything sits
   behind `tabletMode` or `kOptionKeepSessionAlive`, so an upstream change to the
   surrounding code usually merges cleanly, and when it doesn't the conflict is a
   few lines rather than a rewritten file.

### The files that actually conflict

These are upstream's high-traffic files *and* ours:

| File | What we changed |
| --- | --- |
| `flutter/lib/models/model.dart` | tablet mode flag, canvas scale/pan for touch, `hasFrameGeometry` |
| `flutter/lib/common/widgets/remote_input.dart` | `handleTouch`, two-finger scale routing, right-click in mouse mode |
| `flutter/lib/desktop/widgets/remote_toolbar.dart` | touch-sized metrics, keyboard toggle button |
| `flutter/lib/common/widgets/toolbar.dart` | tablet/mouse/keyboard menu entries |
| `flutter/lib/desktop/pages/remote_page.dart` | cursor overlay, paint path, floating button |
| `flutter/lib/mobile/pages/remote_page.dart` | keep-alive start/stop |
| `src/common.rs` | `APP_NAME` override |
| `src/client/io_loop.rs`, `src/ui_session_interface.rs` | background FPS throttle |

### Doing a sync

```
git fetch origin                       # rustdesk/rustdesk
git checkout -b sync/<date> feat/windows-tablet-touch
git merge origin/master
# resolve, then:
flutter analyze --no-pub
```

**The baseline matters.** `flutter analyze` on an untouched tree reports **19
errors / ~343 issues** — all pre-existing (Flutter version skew against the pinned
3.24.5, plus the build-time-generated `generated_bridge.dart`). Anything above that
count is yours. Then build and re-run `docs/windows-tablet-touch-acceptance.md`.

`.github/workflows/upstream-check.yml` runs this merge as a **dry run weekly**, so
you learn upstream has broken something before you sit down to sync rather than
during.

### What does not go upstream

The behavioural fixes — keep-alive, freeze-aware timeout, background throttle —
aren't fork-specific and would benefit upstream. Keep them on a branch free of the
branding and app-ID commits, which must never go up.

---

## Auto-update is off, deliberately

`is_custom_client()` returns true whenever `APP_NAME != "RustDesk"`, which disables
update checking. That's correct rather than a loss: the check asks
`api.rustdesk.com/version/latest` and hands back a URL to an **official RustDesk
release**, so a working updater would offer to replace this build with stock
RustDesk and take both features with it.

Updates come from rebuilding this fork, not from upstream's updater.

## Building

**Windows** — push to `feat/windows-tablet-touch`.
`.github/workflows/windows-touch-build.yml` builds only the Windows client,
skipping ten irrelevant platform jobs, and publishes to the `windows-touch` release
tag. A `concurrency` group cancels superseded runs so two builds can't race to
overwrite the same assets.

**Android** — the full `flutter-nightly` workflow.

## Known gaps

- **The MSI still builds as product "RustDesk"** with upstream's UpgradeCode,
  because `res/msi/preprocess.py` defaults `--app-name` and matches an exe by that
  name. Installing it would collide with a stock RustDesk install; portable builds
  are unaffected. Fixing it means renaming the built binary too.
- Windows handles three- and four-finger touchscreen gestures in the shell before
  any app sees them, so three-finger scroll needs them disabled system-wide
  (`HKCU:\Control Panel\Desktop` → `TouchGestureSetting` = 0, sign out to apply).

## Licence

RustDesk is AGPL-3.0, and so is this fork; see [LICENCE](LICENCE). Source for these
modifications is this repository, which must stay public for as long as builds are
distributed.

The RustDesk name and logo are the upstream project's. AGPL-3.0 grants rights over
the code, not the trademark — §7(e) lets a licensor withhold trademark rights — so
this fork is named and identified separately. It is not an official RustDesk release
and is not endorsed by them.
