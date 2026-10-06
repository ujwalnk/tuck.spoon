# Tuck.spoon

Tuck is a per-Space, per-screen "tuck shelf" for macOS application
windows. You tuck a window against an edge of your current screen: the
real window is hidden the way Cmd+H hides it (see "How windows are
hidden" for the one place it minimizes instead), and a small card takes
its place, parked mostly off-screen until you approach the edge. Click
the card, or type the app's name, to bring the window straight back to
exactly where it was.

**One shortcut does everything:** `Fn+T`, then an arrow to tuck, or
letters to search and restore.

Every screen/Space combination has its own independent set of shelves,
so a card you tuck on your laptop display in Space 1 never shows up on
an external display, or on Space 2, or anywhere else.

## Requirements

- Hammerspoon (current release; Tuck relies on `hs.canvas`,
  `hs.window.filter`, `hs.spaces`, `hs.eventtap`, `hs.screen`, and
  `hs.image`).
- macOS Accessibility permission for Hammerspoon (required for
  Hammerspoon to inspect/manipulate windows at all).
- Screen Recording permission is **optional** and only affects whether
  tuck cards show a thumbnail preview of the window. Everything else
  works identically without it.

## Installation

1. Copy (or symlink) `Tuck.spoon` into `~/.hammerspoon/Spoons/`.
2. In your `~/.hammerspoon/init.lua`:

   ```lua
   hs.loadSpoon("Tuck")
   -- optional: spoon.Tuck:configure({ ... })  -- see Configuration below
   spoon.Tuck:start()
   ```

3. Reload your Hammerspoon configuration.

## Permissions

- **Accessibility**: required for Hammerspoon to inspect, hide, and
  focus windows at all. macOS prompts the first time.
- **Screen Recording**: optional. It only enables thumbnails. Tuck checks
  `hs.screenRecordingState(false)` (never prompting) and captures the
  thumbnail *before* hiding the window (a hidden window cannot be
  captured). Without it, cards show the app icon and name instead.

## Starting/stopping

```lua
spoon.Tuck:start()   -- idempotent; safe to call more than once
spoon.Tuck:stop()    -- idempotent; unbinds shortcuts, stops watchers,
                     -- destroys every card canvas
```

## Shortcut

| Action | Default | Key |
| --- | --- | --- |
| Start a Tuck command (tuck **or** untuck) | `Fn+T` | `shortcuts.tuck` |

There is no separate untuck shortcut. **Pressing it also brings every
currently tucked card fully into view** (still at its normal collapsed
size, not expanded) so you can see what's parked before choosing an
arrow or typing a search letter; cards return to parked the moment the
command ends (tuck, restore, cancel, or timeout).

After `Fn+T`:

| Next key | Result |
| --- | --- |
| `←` `→` `↑` `↓` | tuck the focused window to that edge |
| `A`–`Z` | search tucked apps by name and restore |
| `Esc` | cancel |
| (nothing for `input.commandTimeout`, default 1.5 s) | cancel |

`Fn` is not a normal `hs.hotkey` modifier, so shortcuts containing
`"fn"` use a shared `hs.eventtap`; that is internal. Only the exact
shortcut is consumed; every other key passes through untouched.

Notes: to search for an app starting with **T** while your shortcut is
`Fn+T`, release `Fn` first (holding it re-triggers the shortcut). Once
you have typed a search letter, arrow keys are ignored (they never
restore anything, and never tuck mid-search).

## Tuck workflow

1. Press `Fn+T`.
2. Press an arrow: **Left / Right / Up / Down** tucks the currently
   focused window to that rail.
3. The window is captured (frame, app, icon, thumbnail), then hidden. Its
   frame is never changed, it is never moved off-screen, and it is never
   resized. A card appears on the rail.
4. Focus is explicitly restored to whichever window was genuinely focused
   immediately before the one just tucked -- see "Focus restoration"
   below. If there is no such window, focus is left exactly as macOS
   leaves it after hiding/minimizing; nothing is arbitrarily selected.

`Esc`, or letting the timeout expire, cancels without touching anything.
Windows on All Spaces are refused (see below).

## How windows are hidden

macOS and Hammerspoon only offer hiding at **application** level
(`hs.application:hide()`, exactly what Cmd+H does). There is no
per-window hide in `hs.window` or the Accessibility API, and unhiding an
app reveals every un-minimized window it owns. Tuck's model is one record
per *window*, so app-level hiding is used only where it is exactly
equivalent to hiding that one window:

| Situation when you tuck | Mechanism | Stored as |
| --- | --- | --- |
| It is the app's **only** non-minimized window (on any Space) and the app has no other tuck | app hide (`Cmd+H` style) | `mechanism = "hide"` |
| Anything else (sibling windows open, or the app already has a tucked window) | window minimize | `mechanism = "minimize"` |

So tucking Safari window A while B and C are open minimizes A; B and C
are never hidden or revealed as a side effect. Restore reverses exactly
what tuck did, and always focuses the specific window by its window ID
(never "the app's main window"). A hide-tucked window is always the only
tuck record of its app, so an unhide can never reveal something that is
still supposed to be tucked.

This limitation is inherent to the platform, not to Tuck. Window
enumeration for the "any Space" check comes from the window filter, which
learns about windows on other Spaces as it observes them; if it cannot
tell, Tuck chooses minimize (the safe option).

## Focus restoration

Tucking a window never leaves focus to chance. The approach is ported
from [MinimizeToPrevious.spoon](https://github.com/ujwalnk/MinimizeToPrevious.spoon):
**focus the previous window first, then hide the current one**, so macOS
never gets to pick (and activate) some other window when the current one
disappears. Tuck is self-contained (the logic is ported, not required as a
dependency).

Order of operations when you tuck window A:

1. Everything needed (frame, thumbnail, identity) is captured while A is
   still on screen.
2. The previous window is chosen **by window ID**: the window genuinely
   focused immediately before A, taken from Tuck's focus history (fed by
   the documented `windowFocused` window-filter event). Only if the
   history has no usable entry does Tuck fall back to what
   MinimizeToPrevious uses: the next visible standard window behind A in
   the front-to-back order (`hs.window.orderedWindows()`), skipping A's own
   application so a sibling is never picked arbitrarily.
3. That exact window is raised and focused.
4. Only then is A hidden/minimized. Nothing is focused afterwards.

A candidate must still exist, be visible, not itself be tucked, and not be
on a Space that is not currently showing (focusing it would pull you to
that Space). If the hide fails, no tuck is recorded and focus goes back to
A.

- **Two different applications:** App A current, App B previous → B.
- **Same application:** Safari A current, Safari B previous → B, by ID.
- **Three same-app windows:** A previous, B current, C exists → tuck B →
  A. C is never chosen.
- **Multiple screens:** the exact previous window, wherever it is.
- **Multiple Spaces:** windows on other Spaces and tucked windows are
  skipped.
- **No valid previous window:** focus is left alone; no sibling window or
  other application is picked.

Tuck's own focus calls (restoring a tucked window, and this refocus) are
never recorded as user focus changes (`window/focus_history.lua`).
`input.focusHistorySize` (default 10) bounds the history; 2 is the minimum.

## Untuck workflow

### 1. Click the card

Restores that window immediately (even mid-search): app unhidden (or
window unminimized), exact frame restored, exact window raised and
focused, record and card removed, rail reflowed.

### 2. Keyboard search: `Fn+T`, then letters

Case-insensitive prefix match on the app name, within the search scope:

- **One match** → restored immediately.
- **Several matches** → all matching cards expand to the hover state so
  you can tell them apart; non-matching cards stay parked. Keep typing to
  narrow (`S` → Safari, Slack, Spotify; `SA` → Safari).
- **No match** → search cancelled, cards collapse.
- `Esc` or timeout cancels. Every accepted letter restarts the timeout.

Multiple windows of the same app are separate cards and separate
matches; matching is on the app name, restoring is by window.

If you reveal a tucked window yourself (Dock click, Cmd+Tab, Cmd+H again,
unminimize), Tuck notices, removes its record and card, and does **not**
re-hide it.

## Search scope vs. physical placement

A card's *physical* position is always exactly one of: one screen, one
Space, one edge. That never changes based on search settings.

Keyboard search, however, has a separate, configurable **scope**:

- `screenAndSpace` (default): typing only searches cards on the screen
  and Space you're currently on.
- `space`: typing searches every card on the current Space, across
  every screen participating in that Space.

Changing this setting never moves a single card — it only changes which
cards keyboard search is willing to match against.

## Rails and stacking

Every screen/Space combination has four independent rails: left, right,
top, and bottom. Each rail can be configured independently for:

- **origin**: `"center"` (default — the stack stays balanced around the
  middle of the edge as cards are added/removed), `"start"` (grows from
  the beginning of the edge), or `"end"` (grows backward from the end of
  the edge).
- **margin**: distance from the start/end of the rail to the
  screen/work-area boundary.
- **padding**: distance between adjacent cards on the rail.

Rails automatically reflow (no gaps, rebalanced stacking) whenever a
window is tucked, restored (by any method), manually unminimized, or
destroyed while tucked.

## Cards, shelves and motion

A card shows (each optional) a thumbnail captured at tuck time, the
app's real icon (from its bundle, never a generic one), the app name, and
the window title.

**Rounded previews.** The screenshot is redrawn once, off-screen, through
a rounded clip path (`hs.canvas` `clip`/`resetClip` +
`canvas:imageFromCanvas()`), so the image itself has transparent rounded
corners — no square corners, no background rectangle — and scaling it
while the card animates never re-renders it. The radius is derived from
`card.cornerRadius` (the card's radius minus the padding around the
picture). Because a baked image scales its corners with it, the radius is
tuned for the geometric mean of the compact and expanded sizes: slightly
rounder than "ideal" when compact and slightly tighter when expanded.
If baking fails, the plain snapshot is used and tucking is unaffected.

**Inward-facing icon.** The app icon badge (shown over a thumbnail) sits
on the side of the card facing the usable screen: bottom-right on left
rails, bottom-left on right rails, bottom-centre on top rails, top-centre
on bottom rails. Only the icon moves; it uses percentage layout like the
rest of the card, so it stays in place across parked, revealed, hovered and
search-expanded states, and on a parked left/right card it sits on the edge
side that stays on screen.

**Left and right rails peek** (`rails.<edge>.peek`, on by default; top and
bottom keep the classic fully-visible layout, and you can turn peek on for
any edge). A card's *size never changes* by parking or revealing, only
its position across the rail; its position *along* the rail (order) never
changes either, so neighbours don't jump.

| State | When | Visible inside the screen |
| --- | --- | --- |
| **Parked** | resting | `card.peekSize` px (default 8) |
| **Edge reveal** | pointer in the trigger strip | `card.edgeRevealSize` px (default 40) |
| **Hover / search match** | pointer over the revealed card, or matched by a search | full card, expanded to `expandedWidth × expandedHeight`, flush with the edge, growing inward, clamped to the screen |

Hover and search expansion coexist: a card that is both stays expanded
until both end.

**Stable interaction (no feedback loop).** The earlier reveal jitter came
from deriving hover from the canvas' own mouse enter/exit events: a card
sliding under a still pointer generated exit/enter events, which retargeted
the animation, which generated more events. Hover is now derived only from
the pointer position, tested against regions computed from each card's
*target* geometry, never from its live animating frame:

- one mouse-moved event tap (running only while a rail has cards; it never
  consumes events, and clicks are unaffected) feeds all decisions;
- the **edge trigger strip** (`card.edgeTriggerSize` deep, default 64,
  deeper than the revealed cards, spanning only the rail's cards) is fixed
  by the screen and slot layout, so it cannot move with a card;
- a card is **entered** when the pointer is inside where the card
  currently rests (parked sliver, or revealed slot once the rail is
  revealed) and **left** only when the pointer leaves its larger expanded
  frame, which is flush with the screen edge and therefore always contains
  the slot it grew from (hysteresis);
- at most one card is hovered; a pointer move computes all state changes
  first and applies each once;
- a rail retracts only after `card.revealGraceDelay` (default 0.18 s) with
  no pointer in its strip or on its cards; re-entry cancels the retract.

So: parked → (pointer enters strip) revealed → (pointer on a card)
expanded, each one animation; resting at the edge changes nothing; moving
away gives one return animation.

**Animation.** One shared, time-based animator (`card/animator.lua`) owns
every move, one animation per card: a new target supersedes the running
one (continuing from the card's *current* on-screen frame), a request for
the target already being approached is ignored, cancelled or replaced
animations can never write again, a destroyed card's animation is
cancelled, frames land exactly on target, progress comes from elapsed time
(frame-rate independent, clamped, monotonic), and the ticker stops when
nothing is animating. `hs.canvas` has no documented native frame tween, so
this is driven by an `hs.timer`.

Limitation: a parked card hangs partly outside its screen. If another
display sits directly beyond that edge, the hidden part can appear on it;
set `rails.<edge>.peek = false` for such edges.

## Configuration

Call `spoon.Tuck:configure({...})` **before** `:start()`. Any field you
omit keeps its default. Example:

```lua
spoon.Tuck:configure({
  shortcuts = { tuck = { mods = { "fn" }, key = "t" } },   -- the ONE shortcut
  input = { commandTimeout = 1.5 },
  card = {
    showAppIcon = true, showThumbnail = true,
    showAppName = true, showWindowTitle = false,
    collapsedWidth = 72, collapsedHeight = 72,   -- card size at the edge
    expandedWidth = 220, expandedHeight = 160,   -- card size on hover/search-match
    cornerRadius = 14, opacity = 0.92, edgeInset = 8,
    backgroundColor = { red = 0.13, green = 0.13, blue = 0.15 },
    borderColor = { red = 1, green = 1, blue = 1 },
    textColor = { red = 1, green = 1, blue = 1 },
    peekSize = 8,          -- parked: how many px stay visible (rest is off-screen)
    edgeRevealSize = 40,   -- pointer near edge: how many px become visible
    edgeTriggerSize = 64,  -- depth of the edge strip that starts the reveal
    revealGraceDelay = 0.18,
    expansionEnabled = true,
  },
  rails = {
    left   = { origin = "center", margin = 12, padding = 10, peek = true },
    right  = { origin = "center", margin = 12, padding = 10, peek = true },
    top    = { origin = "center", margin = 12, padding = 10, peek = false },
    bottom = { origin = "center", margin = 12, padding = 10, peek = false },
  },
  screen = { useWorkArea = true },
  search = { scope = "screenAndSpace" },   -- or "space"
  animation = {
    hoverDuration = 0.18, revealDuration = 0.22, reflowDuration = 0.20,
    easing = "easeOutCubic",               -- | "easeInOutCubic" | "linear"
  },
  logging = { level = "info" },
})
spoon.Tuck:start()
```

Configuration is validated as soon as you call `:configure()` (and
again on `:start()`); an invalid value raises a clear error describing
exactly which field is wrong, rather than starting in a broken state.

## Spaces and screens

Every tucked window remembers exactly one screen and one Space —
whichever it was on at the moment it was tucked — and that assignment
is authoritative. Tuck never tries to re-derive a tucked window's Space
by asking macOS to enumerate minimized windows generically (minimized
windows have special, unreliable Space semantics); it always trusts its
own registry.

Screens positioned anywhere relative to your primary display (left,
right, above, below — including negative coordinates) are handled
correctly, because every calculation is anchored to that screen's own
frame, never assumed to start at `(0, 0)`.

If a screen disconnects, its cards are left in place (not discarded)
along with their underlying tuck records; nothing is silently
reassigned to a different screen. Reconnecting the same screen (same
UUID) restores normal reflow behavior for its shelves. If you tuck a
window and then permanently remove that screen, its record remains
recoverable via keyboard search scoped to `"space"` from any screen
still on that Space, even though its own physical card can no longer be
positioned.

## All Spaces limitation

Windows assigned to **All Spaces** (e.g. via Mission Control's "Assign
To → All Desktops") are not supported and cannot be tucked. Attempting
to tuck one leaves the window untouched (not minimized, no card, no
state created) and shows a brief on-screen notice.

## Manual reveal behavior

If you bring a tucked window back yourself (Dock icon, Cmd+Tab, pressing
Cmd+H again, or unminimizing it), Tuck detects it (application watcher for
hide/unhide, window filter for minimize), quietly removes its record and
card, and does **not** re-hide, move, or resize anything. Closing a tucked
window, or quitting its app, also removes the card. Tuck's own restores
are told apart from manual ones with explicit guards (per app for
unhide, per window for unminimize), not with delays.

## Persistence

Tucks survive Hammerspoon restarts and reloads.

**State file.** `state.json` beside the Spoon (`Tuck.spoon/state.json`,
derived from where `init.lua` was loaded — not from the working directory;
override the folder with `persistence.directory`). It is versioned
(`"version": 1`) plain JSON: for each tuck `tuckID`, `windowID`, `pid`,
`bundleID`, `appName`, `windowTitle`, original `frame`, `spaceID`,
`screenUUID`, `edge`, rail `order`, and how it was hidden (`mechanism`).
No window/canvas/image objects, timers, functions, hover, reveal, search or
animation state are ever stored. Add `state.json`, `state.json.*` and
`cache/` to your `.gitignore` if the Spoon lives in a repository.

**When it is written.** Only when persistent state changes (tuck created,
tuck ended by restore/manual unhide/destroyed window/quit, rail order
change), coalesced into one write after `persistence.debounce` seconds
(0.25), plus a final write on `stop()`. Never during animations. Writes are
atomic: temp file, flush, close, rename over the old file.

**Startup reconciliation.** On `start()` the file is loaded, validated and
each record is matched against real windows:

- the saved `windowID` is trusted only if it resolves to a window of the
  *same process* (saved PID, same bundle ID) whose title or frame matches
  the saved one;
- otherwise a window is adopted only if exactly one window of that process
  matches title **and** frame, is still hidden/minimized, and no other
  record competes for it; several possible candidates → the record is
  dropped (logged) and nothing is attached or hidden;
- window still hidden/minimized → record, shelf slot, rail order and card
  are rebuilt, **parked**, without unhiding anything;
- window already visible (restored while Tuck was not running) → record
  dropped, the window is left alone;
- window/application gone (or the application was relaunched, so the saved
  PID no longer exists) → record dropped.

The cleaned state is persisted immediately. Reconciliation is idempotent:
repeated reloads never duplicate records, cards, watchers, taps or timers.
Safari window A's record is never attached to Safari window B merely
because both are Safari.

**Thumbnails.** App icons are re-read from the app bundle. When
`persistence.persistThumbnails` is on (default) and Screen Recording is
granted, each card's rounded preview is cached as `cache/<tuckID>.png`
and reloaded after a restart; unreferenced cache files are removed. A
missing/unreadable cache file never discards a tuck: the card appears with
the normal blank preview, icon and name.

**Corrupt or unsupported files.** An unparsable file, or one written by a
newer schema, is renamed to `state.json.corrupt-<time>` /
`state.json.unsupported-<time>`, a warning is logged, and Tuck starts
empty and carries on. Individual invalid entries are skipped.

**Limitations.** A saved window ID is not durable across an application
relaunch or reboot, so tucks whose application was quit/relaunched are
dropped rather than guessed at (the hidden windows of a quit application no
longer exist anyway). If a tuck's window is identical in title and frame to
another hidden window of the same application and its ID changed, it is
dropped as ambiguous. A window moved to another Space while Tuck was
stopped keeps its recorded Space. Set `persistence.enabled = false` to keep
everything in memory only.

## Known limitations

- Keyboard search matching is case-insensitive prefix matching only —
  no fuzzy matching, no substring matching, no numeric selectors.
- Hiding is app-level on macOS; per-window hiding does not exist, hence
  the hide/minimize split described above. Windows a hidden app opens
  while it is hidden are outside what Tuck can track.
- While `Fn` is still held, `T` re-triggers the shortcut instead of
  searching; release `Fn` before typing `T`.
- Only standard, single-Space application windows can be tucked
  (`hs.window:isStandard()`); unusual system overlays, transient
  dialogs Hammerspoon itself doesn't consider standard windows, and
  All-Spaces windows are unsupported by design.
- Thumbnails are a single snapshot taken at the moment of tucking; they
  are never refreshed while a window remains parked.
- `hs.spaces` is documented by the Hammerspoon project as relying on
  private, undocumented macOS APIs; if a future macOS/Hammerspoon
  release changes its behavior, Space-aware features (current-Space
  detection, the `"space"` search scope, All-Spaces rejection) may need
  revisiting. Tuck fails safe wherever this API misbehaves — see
  "Testing" below.

## Configuration reference

| Path | Default | Notes |
| --- | --- | --- |
| `shortcuts.tuck` | `{mods={"fn"}, key="t"}` | the only shortcut |
| `input.commandTimeout` | `1.5` | seconds; restarts after each accepted letter |
| `card.showAppIcon` / `showThumbnail` / `showAppName` / `showWindowTitle` | `true`/`true`/`true`/`false` | |
| `card.collapsedWidth` / `collapsedHeight` | `72` / `72` | card size **at the screen edge** (never changed by parking/reveal) |
| `card.expandedWidth` / `expandedHeight` | `220` / `160` | card size on hover / search-match; ≥ collapsed |
| `card.cornerRadius`, `card.opacity` | `14`, `0.92` | opacity is the background's alpha |
| `card.backgroundColor` / `borderColor` / `textColor` | dark gray / white / white | each `{red=,green=,blue=}` in 0–1 |
| `card.edgeInset` | `8` | gap from the edge on non-peek rails |
| `card.peekSize` | `8` | how many px of the card stay visible when parked (the rest sits off-screen); peek rails only |
| `card.edgeRevealSize` | `40` | how many px become visible on edge reveal; ≥ peekSize, ≤ card size |
| `card.edgeTriggerSize` | `64` | depth of the trigger strip; ≥ peekSize (keep > edgeRevealSize) |
| `card.revealGraceDelay` | `0.18` | seconds before a rail retracts |
| `card.expansionEnabled` | `true` | disables hover/search expansion |
| `rails.<edge>.origin` | `"center"` | `"center"`, `"start"`, `"end"` |
| `rails.<edge>.margin` / `padding` | `12` / `10` | rail-end margin; gap between cards |
| `rails.<edge>.peek` | left/right `true`, top/bottom `false` | park mostly off-screen |
| `screen.useWorkArea` | `true` | `false` = full frame |
| `search.scope` | `"screenAndSpace"` | or `"space"` (all screens of the current Space) |
| `animation.hoverDuration` / `revealDuration` / `reflowDuration` | `0.18` / `0.22` / `0.20` | seconds; `0` = instant |
| `animation.easing` | `"easeOutCubic"` | or `"easeInOutCubic"`, `"linear"` |
| `persistence.enabled` | `true` | keep tucks across restarts |
| `persistence.directory` | Spoon directory | where `state.json` / `cache/` live |
| `persistence.debounce` | `0.25` | seconds writes are coalesced |
| `persistence.persistThumbnails` | `true` | cache card previews in `cache/` |
| `logging.level` | `"info"` | |

**Migration.** Old keys are translated automatically: `shortcuts.untuck`
is ignored (there is one shortcut now), `input.directionTimeout` /
`input.searchTimeout` → `input.commandTimeout`, `card.animationDuration` →
`animation.hoverDuration`.

## Architecture

```
Tuck.spoon/
  init.lua                 -- wiring, public start()/stop()/configure()
  config/defaults.lua      -- default config + validation (pure Lua)
  input/
    shortcut.lua           -- hs.hotkey / hs.eventtap abstraction (Fn support)
    state.lua              -- single command state machine: arrow = tuck, letters = search (pure Lua)
    matcher.lua             -- case-insensitive prefix matching (pure Lua)
  window/
    manager.lua             -- capture/tuck/restore/forget, hide-vs-minimize choice, All-Spaces, focus-before-hide, startup reconcile
    tracker.lua              -- window filter (minimize/destroy/focus) + application watcher (hide/unhide/quit)
    focus_history.lua        -- pure MRU stack of genuinely-focused windows (pure Lua)
  space/
    manager.lua              -- current Space/screen resolution, watchers
    geometry.lua              -- pure rail-stacking + expansion math
  card/
    manager.lua                -- canvases, parked/reveal/hover states, position-based pointer model, click
    animator.lua                -- shared time-based frame animator
    renderer.lua                -- builds a card's drawn elements from a TuckedWindow
    preview.lua                  -- Screen Recording permission, snapshot capture, rounded-corner baking, cache I/O
    icon.lua                      -- native app icon cache
  state/
    store.lua                     -- TuckState: windows index + shelves index
    persistence.lua                -- versioned state.json: validation, atomic debounced writes, thumbnail cache
  tests/                           -- see "Testing" below
  README.md
```

**Architectural invariants** (see also the inline comments throughout
the source):

1. `TuckedWindow` (in `state/store.lua`) is the source of truth. Cards
   are views and can always be recreated from it.
2. A tuck record's `screenUUID`/`spaceID` are authoritative once set;
   Tuck never re-derives shelf membership from generic minimized-window
   enumeration.
3. The real window's `windowID` is what identifies it — never the
   bundle ID, which only identifies the application. Multiple windows
   from the same application are always tracked independently.
4. Every restore path (card click, keyboard search, reconciliation)
   converges on exactly one implementation:
   `WindowManager:restore()`.
5. Physical shelf placement and keyboard search scope are independent
   concepts; changing one never changes the other.
6. The real window is only ever hidden or minimized through the normal
   macOS mechanisms — never emulated with frame tricks, moved
   off-screen, or resized.
7. Tuck never fights a user's manual restoration of a tucked window.
8. A hide-tucked window is the only tuck record of its application.
9. Tucking focuses the exact window previously focused BEFORE hiding the
   current one (or leaves focus alone) -- never an arbitrary sibling
   window or application.
10. Hover and edge reveal are decided from the pointer position against
    target geometry, never from an animating canvas' frame or its mouse
    enter/exit events.
11. state.json holds only plain data; a bad file is preserved aside and
    never crashes startup; a record is attached to a window only when it
    can be identified unambiguously.

## Testing

### Automated (no Hammerspoon required)

```
cd Tuck.spoon
lua5.4 tests/run_tests.lua
```

Specs: `config_defaults_spec` (schema, validation, migration),
`geometry_spec` (stacking, depth/peek positions, expansion anchoring and
clamping, trigger strips, negative-coordinate screens), `store_spec`,
`input_state_spec` (shared shortcut; arrows tuck, letters search, arrows
never restore, Esc/timeout, narrowing, timer restarts), `matcher_spec`,
`focus_history_spec` (the pure MRU stack: exact-previous lookup, skipping
invalid/stale entries, suppression of Tuck's own focus calls, bounded
size),
`shortcut_flags_spec`, `animator_spec` (exact landing, monotonic and
time-based progress, replacement continuity, no late writes, no timer
leak, easing), and `integration_spec` (the real `init.lua` against
`tests/mock_hs.lua`: hide vs minimize, exact-window restore and focus,
same-app independence across screens/Spaces, manual unhide/unminimize,
destroy and app quit, All-Spaces rejection, search scopes, parked/reveal/
hover states on every edge, grace-delay stability, rapid hover, idempotent
start/stop and no leaked taps/timers/watchers), `focus_restore_spec`
(the six focus-restoration scenarios, end to end through the real
tracker -> focus_history -> window.manager pipeline), `persistence_spec`
(state file contents/schema, debounced atomic writes, reload
reconstruction of records/shelves/order/cards, no duplicates over repeated
reloads, cleanup on restore/manual unhide/destroy/quit, reconciliation of
visible/gone/ambiguous windows, same-app multi-window/screen/Space
identity, thumbnail cache, corrupt/unsupported files, persistence off) and
`behavior_spec` (focus-before-hide ordering and fallbacks, edge-reveal
stability and absence of oscillation, hysteresis, animation ownership and
cleanup, search expansion, inward icon placement for all four edges,
rounded-thumbnail baking, restart-stable placement and search scope,
single cleanup on restore, start/stop idempotency). Tests persist into
temporary directories, never into the repository.

The mock mirrors documented API signatures, not macOS behavior. Passing
tests mean the logic and wiring are sound; they do **not** show that the
motion looks smooth or that macOS behaves as assumed. Do the manual
checklist below.

### Manual, OS-level validation checklist

The following can only be verified by running Tuck inside real
Hammerspoon on macOS:

**Basic tuck / hiding**
- [ ] `Fn+T` then each arrow tucks to the right rail
- [ ] Single-window app (e.g. VS Code): app hides like Cmd+H
- [ ] Safari with several windows: only the chosen window disappears
  (minimized); the others stay visible
- [ ] Terminal/iTerm2 with several windows behaves the same
- [ ] Window is not moved off-screen and not resized
- [ ] `Fn+T` then letters never tucks; `Fn+T` then an arrow never restores

**Restore**
- [ ] Restore by clicking a card
- [ ] Restore by typing a unique application letter
- [ ] Confirm the original frame is restored exactly
- [ ] Confirm the window receives focus

**Multiple windows**
- [ ] Multiple windows of the same application, tucked independently
- [ ] Same application across multiple screens
- [ ] Same application across multiple Spaces
- [ ] Same application across multiple screens within the same Space

**Application search**
- [ ] Unique first-letter match restores immediately
- [ ] Multiple first-letter matches expand all matching cards
- [ ] Second/third-letter narrowing
- [ ] Zero-match cancellation
- [ ] Esc cancellation
- [ ] Timeout cancellation, including timeout reset after each letter

**Tuck direction mode**
- [ ] Each arrow tucks to the correct rail
- [ ] Esc cancels
- [ ] Timeout cancels
- [ ] Arrow keys do nothing while untucking

**Spaces**
- [ ] Cards stay on the Space they were tucked on when you switch away
  and back
- [ ] Cards never appear on the wrong Space

**Screens**
- [ ] Separate shelves per screen
- [ ] A screen with negative coordinates (positioned left of/above the
  primary display) places cards correctly
- [ ] `screenAndSpace` vs `space` search scope, verified with the same
  application tucked on two different screens in the same Space

**All Spaces**
- [ ] A window assigned to All Spaces cannot be tucked, and Tuck says so

**Lifecycle**
- [ ] Manually unhiding (Dock, Cmd+Tab, Cmd+H) or unminimizing a tucked
  window removes its card and does not re-hide it
- [ ] Destroying (closing) a tucked window removes its state and card
- [ ] Quitting the application behind a tucked window removes its card
- [ ] Repeated `:start()`/`:stop()` is safe (no duplicate shortcuts,
  watchers, or cards)
- [ ] Reloading Hammerspoon's config does not duplicate anything

**Permissions**
- [ ] With Screen Recording granted: thumbnails are captured
- [ ] Without Screen Recording: a blank/icon-only card is shown, and
  tucking still works normally
- [ ] Revoking Accessibility mid-session degrades gracefully (Tuck logs
  and shows feedback rather than crashing)

**Focus after tucking**
- [ ] Focus B, then A; tuck A → B is focused, and no other window of A's
  application comes forward
- [ ] Three windows of one application (A previous, B current, C other):
  tuck B → A is focused, not C
- [ ] Previous window on another screen / another Space behaves as
  documented (no jump to a different Space)
- [ ] No previous window: focus is left alone

**Persistence**
- [ ] Tuck several windows (several screens/Spaces/edges), reload
  Hammerspoon: cards return parked, in the same order, on the right
  screen and Space, windows stay hidden
- [ ] Thumbnails return with Screen Recording granted; blank preview
  without it
- [ ] Manually restore a tucked window, reload: no card, window untouched
- [ ] Quit a tucked app, reload: no card
- [ ] Reload repeatedly: no duplicate cards, taps or timers
- [ ] Corrupt `state.json` by hand: Hammerspoon starts, the file is kept
  as `state.json.corrupt-*`

**Card visuals**
- [ ] Thumbnail corners are rounded (compact and expanded, no square
  corners or rectangle behind them)
- [ ] Icon: bottom-right on left cards, bottom-left on right cards,
  inward on top/bottom cards

**Card motion (look at it!)**
- [ ] Parked left/right cards show only a small sliver
- [ ] Approaching the edge slides cards smoothly to the reveal depth, once;
  holding the pointer at the edge does not jitter or repeat the animation
- [ ] Pointer on the very first screen pixel over a card expands it and
  stays expanded
- [ ] Hovering a card expands it inward, smoothly, with no flicker
- [ ] Rapid in/out and card-to-card movement stay smooth, no oscillation
- [ ] Moving the pointer along the strip and away retracts once, after
  a short delay
- [ ] Search-matched cards expand with the same motion
- [ ] Pressing the shortcut brings every parked card fully into view, and
  it parks again once you tuck, restore, cancel or time out
- [ ] Rapid repeated tuck / untuck leaves no stale cards or hidden apps
- [ ] Clicking near the screen edge (scrollbars) still works

**UI**
- [ ] Collapsed vs. hover-expanded vs. search-expanded card appearance
- [ ] Expansion grows inward and never past the opposite screen edge
- [ ] Click hit-testing on a collapsed card
- [ ] Rail reflow after adding/removing cards (no gaps)
- [ ] Center/start/end stacking, margin, and padding all behave as
  configured

## Troubleshooting

- **Nothing happens when I press the tuck shortcut.** Confirm
  Hammerspoon has Accessibility permission, and that `spoon.Tuck:start()`
  was actually called (check the Hammerspoon console for a "Tuck:
  started" log line).
- **Cards never show a thumbnail.** Check System Settings → Privacy &
  Security → Screen Recording for Hammerspoon, then reload Hammerspoon.
  This never blocks tucking itself.
- **A window won't tuck.** It's likely not a standard application
  window (`hs.window:isStandard()` returned false) or it's assigned to
  All Spaces — both are unsupported by design, not bugs.
- **I want to see more detail in the Hammerspoon console.** Call
  `spoon.Tuck:setLogLevel("debug")` before `:start()`.

## License

MIT.
