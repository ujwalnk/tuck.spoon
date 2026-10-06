# CLAUDE.md — Tuck.spoon

Guidance for anyone (human or AI) changing this Spoon. It describes the
**actual** implementation. Read the "Do not reintroduce" list before
touching anything that listens, polls or animates.

## Purpose

Tuck is a per-Space, per-screen tuck shelf for application windows. One
shortcut (default **Option+F3**, a plain `hs.hotkey`) opens a command:
an arrow tucks the focused window to that edge (the window is hidden or
minimized — its frame is never changed and it is never moved off-screen),
letters search tucked apps by name and restore one. A card per tucked
window parks against the chosen edge; clicking a card restores it. Tucks
persist in `state.json` across Hammerspoon restarts.

The overriding design constraint is **near-zero idle cost**: CPU, wakeups,
battery and memory. While you are not interacting, Tuck must do nothing.

## Layout

| Path | Owns |
| --- | --- |
| `init.lua` | lifecycle (`start/stop`), command mode (temporary keyboard tap + timeout), `_syncResources()` (lazy watchers), dispatch |
| `config/defaults.lua` | defaults, migration, validation (rejects the `fn` modifier) |
| `input/shortcut.lua` | `hs.hotkey` registration only; `_flagsMatch` for the command tap |
| `input/state.lua`, `input/matcher.lua` | pure command state machine and app-name matching |
| `window/manager.lua` | capture/tuck/restore/forget, hide-vs-minimize, focus-before-hide, lifecycle handlers, startup reconciliation |
| `window/tracker.lua` | window filter (unminimized/destroyed/focused only) + application watcher |
| `window/focus_history.lua` | pure most-recently-focused window-ID stack |
| `card/manager.lua` | visual card canvases, sensor (hit/zone) canvases, pointer model, reveal/hover/search state |
| `card/animator.lua` | the only animation code; one ticker alive only while animating |
| `card/renderer.lua`, `icon.lua`, `preview.lua` | card elements (inward icon anchor), app icon cache, screenshot capture + rounded-corner baking + cache I/O |
| `space/manager.lua`, `space/geometry.lua` | screen/Space context and watchers; pure rail geometry |
| `state/store.lua`, `state/persistence.lua` | the single in-memory registry of tucks; versioned atomic `state.json` |
| `tests/` | pure-Lua suites against `tests/mock_hs.lua` |

## Window identity

A tuck is one real window. `TuckedWindow` records are keyed by Tuck's own
`tuckID` and by `windowID`; bundle ID / app name are metadata (search,
icons) and are **never** used to find a window. Windows of one app on
different screens/Spaces are independent records. Physical shelves are
keyed by `screenUUID + spaceID`; each has four rails. Search scope
(`screenAndSpace` | `space`) only filters matching, never placement.
All-Spaces windows are rejected.

## Activation and command mode

`Shortcut:bind` → `hs.hotkey.bind` (Option+F3). Pressing it runs
`_beginCommand()`: starts the one-shot timeout and creates the keyboard
eventtap (arrows, bare letters, Esc; everything else passes through).
Every way out (tuck, restore, cancel, Esc, timeout, `stop()`) goes through
`_endCommand()` which stops the timer and destroys the tap immediately.
There is no Fn/F20/Karabiner path anywhere; `fn` in a shortcut is a
validation error. On laptops F3 needs "standard function keys" or `fn`
held — that is a macOS setting, not Tuck logic.

## Resource lifecycle (the contract)

| State | Resources |
| --- | --- |
| Idle | hotkey only |
| Command | + keyboard tap + timeout timer (torn down at command end) |
| Tucked | + window filter (3 events), app watcher, screen watcher, Space watcher, card canvases, sensor canvases |
| Animating | + `doEvery` ticker (nil when finished) |
| Write pending | + one `doAfter` debounce timer |
| Last tuck removed | back to Idle (`init.lua:_syncResources`, `cardManager:releaseIdleResources`) |

`_syncResources()` runs from `windowManager.onStateChanged` (every tuck
created/ended) and after startup reconciliation. It is the only place the
tracker and Space/screen watchers are started/stopped. The one-shot
safety-net timers (3 s, `_guardAfter`) guard internal restore/focus flags
and expire on their own; they are not polling.

## Focus restoration (MinimizeToPrevious approach)

`WindowManager:tuck` captures state while the window is visible, then
**focuses the previous window first and hides the current one second**, so
macOS never chooses. Previous window = focus history (window IDs, fed by
`windowFocused`, authoritative while tucks exist) else the window behind
the target in `hs.window.orderedWindows()` (macOS z-order is focus
recency; used for the first tuck because no filter exists while idle).
Candidates must exist, be visible, not be tucked, and be on an active
Space. Focusing uses `app:activate()` + `win:raise()` + `win:focus()` —
**never `activate(true)`**, which raises every window of the app. A failed
hide restores focus and creates no record. Tuck's own focus calls are
registered with `focusHistory:suppressNextFocus/record` so they do not
corrupt history.

## Unrelated-window integrity

Tuck writes **no frame** on tuck. On restore it writes the saved frame to
exactly one window — the record's — and only if `_belongsToRecord` (same
PID) holds. Focus never uses app-wide activation. The suspected causal
path for earlier "unrelated window moved" reports is the app-wide
`activate(true)` raise plus restore-by-ID without an identity check; both
are fixed and covered by `lifecycle_spec` (section I). The report could not
be reproduced outside a real macOS session, so verify manually.

## Cards and hover

The visible card canvas has **no mouse callback** (click-through).
Pointer events come from stationary sensor canvases using
`canvasMouseEvents` enter/exit (verified in Hammerspoon's canvas source: a
canvas with a mouse callback captures events — and clicks — over its whole
area; one without is click-through):
- one **zone** canvas per peek rail (edge trigger strip, `edgeTriggerSize`);
- one **hit** canvas per card: the on-screen part of its *target* resting
  slot, or its expanded frame while hovered (flush with the edge ⇒
  hysteresis). Sensors move only on state changes, never per frame. The
  hovered sensor is raised above neighbours.
- `_setHover`, `_onZone`, `_onHitEnter/Exit` are idempotent; rails keep a
  set of pointer sources and retract after `revealGraceDelay` (one-shot).
The jitter fix is preserved: motion is target-based, an unchanged target is
ignored by the animator, and nothing that moves is ever the event source.
Icon placement is `Renderer.inwardAnchor(edge)`; thumbnails are baked once
with rounded corners in `card/preview.lua` (radius from `card.cornerRadius`).

## Animation

`card/animator.lua`: one shared time-based ticker, started on the first
animation and stopped (`ticker = nil`) when none remain; one animation per
card; new target supersedes; same target ignored; destroying a card cancels
its animation; final tick assigns the exact target.

## Persistence

`state.json` in the Spoon directory (override `persistence.directory`),
schema version 1, plain JSON only. Debounced (`persistence.debounce`),
atomic (temp + rename), scheduled only by real state changes. Corrupt or
newer files are renamed `state.json.corrupt-<t>` / `.unsupported-<t>`.
Startup (`WindowManager:reconcile`) trusts a saved windowID only if it
resolves to a window of the same PID/bundle whose title or frame matches;
otherwise adopts a window only if exactly one unclaimed window matches
title **and** frame and no other record competes; ambiguous/visible/gone
records are dropped. Nothing is ever unhidden or re-hidden at startup, and
startup does not enumerate windows via `orderedWindows`. Thumbnails cache in
`cache/<tuckID>.png`; a missing file never drops a tuck.

## Testing

```sh
lua5.4 tests/run_tests.lua       # from the Spoon directory
```

`tests/mock_hs.lua` models hotkeys, eventtaps, timers (virtual clock),
canvases (mouse sensors with z-order and click-through), watchers, windows
with focus-recency z-order, `hs.json`/`hs.fs`. `tests/harness.lua` has
`boot/reload/tuck/click/resources`. `lifecycle_spec` asserts the resource
table above, GC-ability after the last tuck, sensor stability and
unrelated-window integrity. Tests write only to temp directories. The mock
cannot prove real AppKit behaviour: do the manual checklists in README.md
(resources via Activity Monitor / `powermetrics`, focus, hover, restart).

## Known limitations

- Option+F3 may conflict with other software; configurable.
- Sensor canvases capture clicks in rail zones / card slots (see README).
- The lazily-started window filter does not know other-Space windows it
  has not seen, which can affect the hide-vs-minimize decision for the
  first tuck of an app (README, "Resource model").
- `hs.spaces` is experimental; every call is guarded.
- Real-OS behaviour (tracking-area events on resized canvases, Accessibility
  quirks) was not validated in this repository's automated tests.

## Do not reintroduce

- A permanent keyboard eventtap for activation, or any Fn/F20 path.
- A permanent or global `mouseMoved` eventtap, or any timer that polls the
  pointer; enter/exit events from a *moving* canvas.
- `hs.timer.doEvery` for anything but the animation ticker; any recurring
  idle timer, periodic window/Space/screen/focus polling or reconciliation.
- Hover debounce delays (the single `revealGraceDelay` one-shot is existing,
  documented behaviour).
- Window-filter subscriptions nobody consumes (`windowMoved`,
  `windowTitleChanged`), or a window filter / watcher that outlives the
  last tuck.
- Periodic or repeated screenshots; screenshots outside tuck time.
- An always-running animation ticker.
- Identifying a window by app name or bundle ID; `activate(true)`;
  writing a frame to any window except the restored record's own.
- Eager creation of canvases, caches or watchers "just in case".
