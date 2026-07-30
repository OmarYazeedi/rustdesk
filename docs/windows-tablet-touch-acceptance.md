# Tablet mode — acceptance checklist

For the first run of the `RustDesk Touch` build on the Surface Go 3, controlling
the desktop. Nothing below has been exercised on hardware; this is the list that
turns "it compiles" into "it works".

Get the build from the `Windows Touch Build` run on the fork, artifact
`rustdesk-unsigned-windows-x86_64`. It's a portable folder — unzip and run
`rustdesk.exe`, no install.

**Detach the keyboard cover before testing.** With it attached the trackpad
reports as a mouse and none of the touch paths are exercised.

## 0. It's a separate app

- [ ] Window title and Task Manager say **RustDesk Touch**, not RustDesk.
- [ ] `%APPDATA%` has its own config dir; your existing RustDesk install is
      untouched and still has its peer list.
- [ ] Expect a **fresh device ID and an empty peer list** — that's the point of
      shipping it separately. Add the desktop by ID.

## 1. Nothing changed with tablet mode off (the regression check)

Do this first, and with a mouse attached.

- [ ] Connect, drive the session with a mouse: click, drag, scroll, right-click.
- [ ] Scrollbars still appear when the remote screen overflows the window.
- [ ] View styles (original / adaptive / custom scale) behave as before.
- [ ] Two-finger pinch on a trackpad still forwards to the peer rather than
      zooming locally.

If any of this differs, the flag is leaking — stop and report.

## 2. Turning it on

- [ ] Toolbar → **Tablet mode** toggle is present and turns on.
- [ ] It survives a session restart (it's a machine-wide local option).

## 3. Touch mode (the default when tablet mode goes on)

- [ ] Single tap clicks at the point touched.
- [ ] Double tap double-clicks.
- [ ] One-finger drag drags (select text, move a window).
- [ ] Long-press gives a right click.
- [ ] Two-finger tap gives a right click.
- [ ] Three-finger vertical drag scrolls.

## 4. Mouse mode — the main thing that didn't exist before

Toolbar → **Mouse mode**.

- [ ] A cursor is **visible** on screen. If there's no cursor, the `CursorPaint`
      change didn't take — report it, this is the likeliest failure.
- [ ] Dragging anywhere glides the cursor trackpad-style, without warping it to
      the finger.
- [ ] Tap clicks at the cursor, not under the finger.
- [ ] Two-finger tap right-clicks at the cursor.
- [ ] The cursor stays inside the remote screen at the edges.

## 5. Pinch zoom and pan — the fiddliest part

- [ ] Pinch out zooms into the remote screen; pinch in zooms out.
- [ ] Zoom centres on the fingers rather than jumping to a corner.
- [ ] While zoomed in, two-finger drag pans.
- [ ] Panning stops at the edges instead of sliding off into grey.
- [ ] **Resize or move the session window while zoomed — the zoom must survive.**
      If it snaps back to fit, the `updateViewStyle` guard isn't holding.
- [ ] Switch remote monitors and back; zoom should still be yours.
- [ ] Turning tablet mode off returns the canvas to the view style cleanly.

Known risk: with the texture render path the paint branch was changed to draw at
the canvas offset. If zooming shows a clipped, stretched or misplaced image rather
than a clean magnification, that's this — say what it looks like.

## 6. Touch keyboard

Toolbar → **Touch keyboard**.

- [ ] It appears docked at the bottom and its taps type rather than clicking the
      remote screen behind it.
- [ ] Letters, digits and punctuation all arrive correctly. Check `` ` ``, `\`
      and `.` specifically — those three go as literal characters rather than
      `VK_*` names and are the most likely to misbehave.
- [ ] Shift capitalises exactly one letter, then releases.
- [ ] Ctrl latches: Ctrl then C copies, and Ctrl stays lit for a following V.
- [ ] Arrows, Enter, Backspace, Tab, Esc.
- [ ] **Fn** reveals F1–F12 and the Ins/Del/Home/End/PgUp/PgDn row.
- [ ] **Win** opens the remote Start menu, *not* the Surface's own. This is the
      whole reason the keyboard is drawn in-app rather than using Windows' —
      if the local Start menu opens, something is falling through to the host.
- [ ] Alt+Tab switches windows on the remote, not locally.
- [ ] Ctrl+Alt+Del reaches the remote.
- [ ] **Hide ⌄** dismisses it.

## 7. Ergonomics, for the follow-up list

Not pass/fail — just note what's wrong so it can be fixed with real information
rather than guesses.

- [ ] Are the toolbar buttons too small to hit reliably? They're 32px; the touch
      guideline is ~44px, and bumping them was deliberately deferred until this
      question could be answered by a finger rather than by me.
- [ ] Is the keyboard the right height, or does it eat too much screen?
- [ ] Does the pinch feel right, or too fast / too slow / too jumpy?
- [ ] Anything that needs a mode switch it shouldn't.
