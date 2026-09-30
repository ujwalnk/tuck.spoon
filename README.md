# Tuck.spoon

Tuck is a per-Space, per-screen "tuck shelf" for macOS application
windows. Instead of switching to another Space or digging through
Mission Control, you tuck a window against an edge of your current
screen: the real window is minimized the normal macOS way, and a small
visual card takes its place on the edge you chose. Click the card, or
type the app's name, to bring the window straight back to exactly where
it was.

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

- **Accessibility**: the first time Hammerspoon tries to minimize,
  move, or inspect a window, macOS will prompt you to grant
  Accessibility permission in System Settings → Privacy & Security →
  Accessibility, if you haven't already. Tuck cannot function at all
  without this.
- **Screen Recording**: entirely optional. Tuck checks
  `hs.screenRecordingState(false)` (without prompting) before every
  capture attempt, so a missing Screen Recording permission never
  interrupts a tuck or triggers a permission dialog. If it's
  unavailable, cards simply show the application's icon and name
  instead of a thumbnail. Grant it in System Settings → Privacy &
  Security → Screen Recording if you want thumbnails, and reload
  Hammerspoon afterward.

## Starting/stopping

```lua
spoon.Tuck:start()   -- idempotent; safe to call more than once
spoon.Tuck:stop()    -- idempotent; unbinds shortcuts, stops watchers,
                     -- destroys every card canvas
```

## Default shortcuts

| Action | Default | Configurable key |
| --- | --- | --- |
| Tuck (enter direction-selection mode) | `Fn+T` | `shortcuts.tuck` |
| Untuck (enter application-search mode) | `Cmd+Shift+T` | `shortcuts.untuck` |

`Fn` is not a normal `hs.hotkey` modifier, so any shortcut spec that
includes `"fn"` is registered through a shared `hs.eventtap` instead of
`hs.hotkey`; this is entirely internal — the rest of the Spoon (and you,
configuring it) never has to think about which mechanism is in use.

## Tuck workflow

1. Press the tuck shortcut. Tuck enters a short direction-selection
   window (default 1.5s, configurable).
2. Press an arrow key:
   - **Left** → tuck to the left rail
   - **Right** → tuck to the right rail
   - **Up** → tuck to the top rail
   - **Down** → tuck to the bottom rail
3. The focused window is minimized the normal macOS way (it is never
   moved off-screen, resized, or faked with frame tricks — it stays
   under ordinary macOS minimized-window management) and a card appears
   on the chosen rail.

Press **Esc** at any point during direction-selection to cancel without
changing anything. If no arrow is pressed before the timeout, Tuck
silently returns to idle.

Arrow keys are *only* ever used for choosing a tuck direction. They are
never used for untucking, and they do nothing outside of
direction-selection mode.

## Untuck workflow

There are exactly two ways to bring a tucked window back:

### 1. Click the card

Clicking a card immediately restores the window it represents: the
window is unminimized, its exact pre-tuck frame is restored, and it is
focused and raised. This works even if a keyboard search is currently in
progress — clicking a card always wins immediately, cancels the search,
and collapses any other cards that had expanded for the search.

### 2. Keyboard search

1. Press the untuck shortcut (default `Cmd+Shift+T`). Tuck enters a
   short application-search window (default 1.5s, reset after each
   letter you type; configurable).
2. Type letters (A–Z only). Matching is a case-insensitive prefix match
   against each tucked window's application name:
   - **S** matches Safari, Slack, and Spotify.
   - **SA** narrows to Safari.
   - **V** matches "Visual Studio Code".
3. As soon as your typed letters match exactly **one** tucked window,
   it is restored immediately.
4. If your letters match **more than one** window, every matching
   card automatically expands to the same larger, emphasized state used
   by mouse hover, so you can see your options while non-matching cards
   stay compact. Keep typing to narrow further.
5. If your letters match **no** window, the search is cancelled, any
   search-expanded cards collapse back down, and Tuck returns to idle.

Press **Esc** at any point during a search to cancel immediately.
There is no fuzzy or substring matching in v1 — only case-insensitive
prefix matching on the application name.

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

## Cards

A card can show, each independently toggleable:

- a cached thumbnail of the window (captured once, at the moment of
  tucking — never re-captured while parked)
- the application's real macOS icon (via `hs.image.imageFromAppBundle`
  — never a generic placeholder, never downloaded, never bundled)
- the application's name
- the window's title (off by default)

Cards are collapsed by default. Hovering a card, or having it match an
in-progress keyboard search, expands it to a larger, more detailed
state; if both conditions are true at once it stays expanded until
*both* end. Expansion always grows inward, toward the screen, never
toward or past the opposite screen boundary, and the card's anchor
point on its rail never moves while it expands.

## Configuration

Call `spoon.Tuck:configure({...})` **before** `:start()`. Any field you
omit keeps its default. Example:

```lua
spoon.Tuck:configure({
  shortcuts = {
    tuck = { mods = { "fn" }, key = "t" },
    untuck = { mods = { "cmd", "shift" }, key = "t" },
  },
  input = {
    directionTimeout = 1.5,
    searchTimeout = 1.5,
  },
  card = {
    showAppIcon = true,
    showThumbnail = true,
    showAppName = true,
    showWindowTitle = false,
    collapsedWidth = 72,
    collapsedHeight = 72,
    expandedWidth = 220,
    expandedHeight = 160,
    cornerRadius = 14,
    opacity = 0.92,
    edgeInset = 8,
    expansionEnabled = true,
    animationDuration = 0.12,
  },
  rails = {
    left = { origin = "center", margin = 12, padding = 10 },
    right = { origin = "center", margin = 12, padding = 10 },
    top = { origin = "center", margin = 12, padding = 10 },
    bottom = { origin = "center", margin = 12, padding = 10 },
  },
  screen = {
    useWorkArea = true, -- false = use the full screen frame, ignoring menu bar/dock
  },
  search = {
    scope = "screenAndSpace", -- or "space"
  },
  animation = {
    hoverDuration = 0.12,
    tuckRestoreDuration = 0.0,
  },
  logging = {
    level = "info", -- "debug" | "info" | "warning" | "error"
  },
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

## Manual unminimize behavior

If you manually unminimize a tucked window yourself (clicking its Dock
icon, `Cmd+Tab`-ing to it, etc.) instead of using a Tuck untuck
mechanism, Tuck notices via its window-lifecycle tracker and quietly
removes its own state and card — it does **not** re-minimize the window,
fight your action, or move/resize it back. Tuck never fights a user's
manual restoration of a tucked window.

## Persistence / restart limitations

Tuck prioritizes runtime correctness over persistence across restarts.
A window's identity is its live macOS/Hammerspoon window ID, which is
**not** meaningfully durable across an application relaunch or a system
restart. Rather than risk reattaching a saved tuck record to the wrong
new window, Tuck's persistence (disabled by default) only ever writes
an informational snapshot — application name, bundle ID, window title,
screen/Space identity, and frame — and, on the next start, logs a
one-line notice of how many windows were tucked in the previous session.
**It never automatically restores anything from that snapshot.** If you
need a window back after a restart, just re-tuck it.

## Known limitations

- Keyboard search matching is case-insensitive prefix matching only —
  no fuzzy matching, no substring matching, no numeric selectors.
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

| Path | Type | Default | Notes |
| --- | --- | --- | --- |
| `shortcuts.tuck` | `{mods, key}` | `{mods={"fn"}, key="t"}` | |
| `shortcuts.untuck` | `{mods, key}` | `{mods={"cmd","shift"}, key="t"}` | |
| `input.directionTimeout` | number (seconds) | `1.5` | |
| `input.searchTimeout` | number (seconds) | `1.5` | resets on each accepted letter |
| `card.showAppIcon` | boolean | `true` | |
| `card.showThumbnail` | boolean | `true` | permission-gated; see above |
| `card.showAppName` | boolean | `true` | |
| `card.showWindowTitle` | boolean | `false` | |
| `card.collapsedWidth`/`collapsedHeight` | number | `72`/`72` | |
| `card.expandedWidth`/`expandedHeight` | number | `220`/`160` | must be ≥ collapsed |
| `card.cornerRadius` | number | `14` | |
| `card.opacity` | number 0–1 | `0.92` | |
| `card.edgeInset` | number | `8` | distance from screen/work-area edge |
| `card.expansionEnabled` | boolean | `true` | disable hover/search expansion entirely |
| `card.animationDuration` | number (seconds) | `0.12` | `0` disables animation |
| `rails.<edge>.origin` | `"center"\|"start"\|"end"` | `"center"` | per left/right/top/bottom |
| `rails.<edge>.margin` | number | `12` | |
| `rails.<edge>.padding` | number | `10` | |
| `screen.useWorkArea` | boolean | `true` | `false` = full screen frame |
| `search.scope` | `"screenAndSpace"\|"space"` | `"screenAndSpace"` | |
| `animation.hoverDuration` | number | `0.12` | |
| `animation.tuckRestoreDuration` | number | `0.0` | |
| `logging.level` | `"debug"\|"info"\|"warning"\|"error"` | `"info"` | |

## Architecture

```
Tuck.spoon/
  init.lua                 -- wiring, public start()/stop()/configure()
  config/defaults.lua      -- default config + validation (pure Lua)
  input/
    shortcut.lua           -- hs.hotkey / hs.eventtap abstraction (Fn support)
    state.lua              -- direction-selection & app-search state machine (pure Lua)
    matcher.lua             -- case-insensitive prefix matching (pure Lua)
  window/
    manager.lua             -- capture/tuck/restore/forget, eligibility, All-Spaces
    tracker.lua              -- hs.window.filter sensor (minimized/unminimized/destroyed)
  space/
    manager.lua              -- current Space/screen resolution, watchers
    geometry.lua              -- pure rail-stacking + expansion math
  card/
    manager.lua                -- canvas lifecycle, hover/search-expand, click handling
    renderer.lua                -- builds a card's drawn elements from a TuckedWindow
    preview.lua                  -- Screen Recording permission + snapshot capture
    icon.lua                      -- native app icon cache
  state/
    store.lua                     -- TuckState: windows index + shelves index
    persistence.lua                -- optional, conservative session snapshot
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
6. The real application window always stays under ordinary macOS
   minimized-window management — Tuck never emulates minimizing with
   frame tricks, moves a window off-screen, or resizes it.
7. Tuck never fights a user's manual restoration of a tucked window.

## Testing

### Automated (pure Lua, no Hammerspoon required)

```
cd Tuck.spoon
lua5.4 tests/run_tests.lua
```

This runs, entirely outside of Hammerspoon:

- `config_defaults_spec` — configuration merge + validation
- `geometry_spec` — rail-stacking and expansion math (center/start/end
  origin, negative-coordinate screens, reflow-without-gaps, expansion
  clamping)
- `store_spec` — the TuckState windows/shelves indexes (multiple
  windows per app, multiple screens/Spaces, idempotent removal)
- `input_state_spec` — the direction-selection and app-search state
  machine (every transition in the spec, including timeouts, Esc, and
  zero/one/many-match search outcomes)
- `matcher_spec` — case-insensitive prefix matching
- `shortcut_flags_spec` — exact-match logic for Fn-based shortcuts
- `integration_spec` — the **real** `init.lua`, loaded against a mock
  `hs` implementation (`tests/mock_hs.lua`), exercising full tuck →
  restore cycles, Esc/timeout cancellation, keyboard search (unique,
  multiple-match, zero-match), manual-unminimize detection, window
  destruction cleanup, All-Spaces rejection, multiple-windows-per-app
  independence, and start/stop idempotency

As of this writing the suite reports **225 assertions, 0 failures**
across all 7 spec files.

The mock `hs` module is deliberately narrow: it mirrors the
**documented signatures** of the Hammerspoon APIs Tuck uses, not real
macOS behavior, which cannot be reproduced outside of Hammerspoon
itself. Treat a passing test suite as "the wiring between modules is
sound," not as "this has been validated on macOS."

### Manual, OS-level validation checklist

The following can only be verified by running Tuck inside real
Hammerspoon on macOS:

**Basic tuck**
- [ ] Tuck a normal app window left/right/top/bottom
- [ ] Confirm the real window is minimized (visible in Mission Control /
  Dock as minimized)
- [ ] Confirm it is not moved off-screen and not resized

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
- [ ] Manually unminimizing a tucked window removes its card
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
