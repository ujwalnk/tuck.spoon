--- Integration test: exercises the REAL init.lua (not a reimplementation)
-- against tests/mock_hs.lua. This validates the wiring between modules
-- -- method names, argument order, control flow -- which the isolated
-- unit tests (by design) cannot reach. It is still not a substitute for
-- the manual OS-level validation checklist in README.md: the mock hs
-- module encodes assumptions about real Hammerspoon behavior that only
-- Hammerspoon itself can ultimately confirm.

local t = require("tests.testkit")

local function freshHs()
  -- Force a clean require of the mock each time so tests don't leak
  -- windows/canvases/timers into one another.
  package.loaded["tests.mock_hs"] = nil
  return require("tests.mock_hs")
end

local function loadSpoon(hsMock)
  _G.hs = hsMock
  -- init.lua is written to be loaded the way hs.loadSpoon() loads real
  -- Spoons: as a standalone chunk, not a `require`-able module (it has
  -- no `package.loaded` entry of its own). dofile mirrors that.
  package.loaded["config.defaults"] = nil
  package.loaded["input.shortcut"] = nil
  package.loaded["input.state"] = nil
  package.loaded["input.matcher"] = nil
  package.loaded["state.store"] = nil
  package.loaded["state.persistence"] = nil
  package.loaded["space.manager"] = nil
  package.loaded["space.geometry"] = nil
  package.loaded["card.icon"] = nil
  package.loaded["card.preview"] = nil
  package.loaded["card.manager"] = nil
  package.loaded["card.renderer"] = nil
  package.loaded["window.tracker"] = nil
  package.loaded["window.manager"] = nil
  local chunk = assert(loadfile("./init.lua"))
  local obj = chunk()
  return obj:init()
end

local function run()
  t.reset()

  -- Basic lifecycle: init/start/stop are safe, idempotent, and a full
  -- tuck->restore cycle works end to end through the real modules.
  do
    local hsMock = freshHs()
    local Tuck = loadSpoon(hsMock)
    Tuck:start()
    Tuck:start() -- idempotent

    local win = hsMock._makeWindow({ appName = "Safari", bundleID = "com.apple.Safari", title = "Example" })
    hsMock._focusedWindow = win

    -- Simulate Fn+T then Left arrow.
    local consumed = hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    t.isTrue(consumed, "Fn+T is consumed by the tuck-shortcut eventtap")
    t.eq(Tuck.inputStateMachine:current(), "waitingForDirection")

    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.left, flags = {} })
    t.eq(Tuck.inputStateMachine:current(), "idle", "arrow completes the tuck and returns to idle")
    t.isTrue(win.isMinimized(), "focused window was actually minimized")

    local record = Tuck.store:getByWindowID(win.id())
    t.isTrue(record ~= nil, "a TuckedWindow record now exists")
    t.eq(record.edge, "left")
    t.eq(record.appName, "Safari")

    local canvas = Tuck.cardManager.canvases[record.tuckID]
    t.isTrue(canvas ~= nil, "a card canvas was created for the tuck")

    -- Restore via simulated card click.
    canvas._fireMouse("mouseUp")
    t.isNil(Tuck.store:getByWindowID(win.id()), "record removed after card-click restore")
    t.isTrue(canvas._isDeleted(), "canvas destroyed after restore")
    t.isFalse(win.isMinimized(), "window unminimized after restore")

    Tuck:stop()
    Tuck:stop() -- idempotent
  end

  -- Esc cancels direction mode without tucking anything.
  do
    local hsMock = freshHs()
    local Tuck = loadSpoon(hsMock)
    Tuck:start()
    local win = hsMock._makeWindow({ appName = "Slack", bundleID = "com.slack" })
    hsMock._focusedWindow = win

    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    t.eq(Tuck.inputStateMachine:current(), "waitingForDirection")
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.escape, flags = {} })
    t.eq(Tuck.inputStateMachine:current(), "idle")
    t.isFalse(win.isMinimized(), "Esc must not tuck the window")
    Tuck:stop()
  end

  -- Direction timeout cancels without tucking.
  do
    local hsMock = freshHs()
    local Tuck = loadSpoon(hsMock)
    Tuck:start()
    local win = hsMock._makeWindow({ appName = "Terminal", bundleID = "com.apple.Terminal" })
    hsMock._focusedWindow = win

    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    t.eq(Tuck.inputStateMachine:current(), "waitingForDirection")
    hsMock._fireAllTimers() -- fires the direction timeout
    t.eq(Tuck.inputStateMachine:current(), "idle")
    t.isFalse(win.isMinimized(), "timeout must not tuck the window")
    Tuck:stop()
  end

  -- Keyboard untuck: unique-letter immediate restore.
  do
    local hsMock = freshHs()
    local Tuck = loadSpoon(hsMock)
    Tuck:start()

    local win1 = hsMock._makeWindow({ appName = "Safari", bundleID = "com.apple.Safari" })
    hsMock._focusedWindow = win1
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.left, flags = {} })

    local win2 = hsMock._makeWindow({ appName = "Terminal", bundleID = "com.apple.Terminal" })
    hsMock._focusedWindow = win2
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.right, flags = {} })

    t.isTrue(win1.isMinimized())
    t.isTrue(win2.isMinimized())

    -- Cmd+Shift+T (untuck shortcut) -- note flags.cmd is held for THIS
    -- keystroke, so our own letter-eventtap guard must not double-count
    -- it as a search letter.
    hsMock._pressHotkey({ "cmd", "shift" }, "t")
    t.eq(Tuck.inputStateMachine:current(), "waitingForAppLetter")

    -- "T" (bare, no modifiers) should uniquely match Terminal and
    -- restore it immediately.
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = {}, chars = "t" })
    t.eq(Tuck.inputStateMachine:current(), "idle", "unique letter match restores and returns to idle")
    t.isFalse(win2.isMinimized(), "Terminal was restored")
    t.isTrue(win1.isMinimized(), "Safari remains tucked (not the match)")

    Tuck:stop()
  end

  -- Keyboard untuck: multiple matches expand, then narrow to one.
  do
    local hsMock = freshHs()
    local Tuck = loadSpoon(hsMock)
    Tuck:start()

    local safari = hsMock._makeWindow({ appName = "Safari", bundleID = "com.apple.Safari" })
    hsMock._focusedWindow = safari
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.left, flags = {} })

    local slack = hsMock._makeWindow({ appName = "Slack", bundleID = "com.slack" })
    hsMock._focusedWindow = slack
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.left, flags = {} })

    hsMock._pressHotkey({ "cmd", "shift" }, "t")
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.s, flags = {}, chars = "s" })
    t.eq(Tuck.inputStateMachine:current(), "waitingForAppLetter", "two matches (Safari/Slack) keep search alive")

    local safariRecord = Tuck.store:getByWindowID(safari.id())
    t.isTrue(Tuck.cardManager.searchMatched[safariRecord.tuckID], "Safari card marked as search-matched")

    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.a, flags = {}, chars = "a" })
    t.eq(Tuck.inputStateMachine:current(), "idle", "second letter narrows to unique Safari match")
    t.isFalse(safari.isMinimized(), "Safari restored")
    t.isTrue(slack.isMinimized(), "Slack remains tucked")

    Tuck:stop()
  end

  -- Manual unminimize (not via Tuck) is detected and cleans up state.
  do
    local hsMock = freshHs()
    local Tuck = loadSpoon(hsMock)
    Tuck:start()

    local win = hsMock._makeWindow({ appName = "Mail", bundleID = "com.apple.mail" })
    hsMock._focusedWindow = win
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.left, flags = {} })
    local record = Tuck.store:getByWindowID(win.id())
    t.isTrue(record ~= nil)

    -- Directly call unminimize() as if the user clicked the Dock icon --
    -- NOT through Tuck.windowManager:restore().
    win.unminimize()

    t.isNil(Tuck.store:getByWindowID(win.id()), "manual unminimize removes the tuck record")
    t.isTrue(Tuck.cardManager.canvases[record.tuckID] == nil, "manual unminimize destroys the card")

    Tuck:stop()
  end

  -- Window destroyed while tucked cleans up (no orphaned card/state).
  do
    local hsMock = freshHs()
    local Tuck = loadSpoon(hsMock)
    Tuck:start()

    local win = hsMock._makeWindow({ appName = "Preview", bundleID = "com.apple.Preview" })
    hsMock._focusedWindow = win
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.left, flags = {} })
    local record = Tuck.store:getByWindowID(win.id())

    win._destroy()

    t.isNil(Tuck.store:getByWindowID(win.id()), "destroyed window's record is removed")
    t.isTrue(Tuck.cardManager.canvases[record.tuckID] == nil, "destroyed window's card is removed")

    Tuck:stop()
  end

  -- All-Spaces windows are rejected: no state, no card, window not minimized.
  do
    local hsMock = freshHs()
    hsMock.spaces.windowSpaces = function(_window)
      return { 1, 2, 3 } -- multiple spaces => "All Spaces"
    end
    local Tuck = loadSpoon(hsMock)
    Tuck:start()

    local win = hsMock._makeWindow({ appName = "Weird", bundleID = "com.example.weird" })
    hsMock._focusedWindow = win
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.left, flags = {} })

    t.isFalse(win.isMinimized(), "All-Spaces window must not be minimized")
    t.isNil(Tuck.store:getByWindowID(win.id()), "no TuckedWindow record created for an All-Spaces window")

    Tuck:stop()
  end

  -- Multiple windows of the same application remain independently
  -- tucked/restorable.
  do
    local hsMock = freshHs()
    local Tuck = loadSpoon(hsMock)
    Tuck:start()

    local a = hsMock._makeWindow({ id = 4812, appName = "Safari", bundleID = "com.apple.Safari", title = "A" })
    hsMock._focusedWindow = a
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.left, flags = {} })

    local b = hsMock._makeWindow({ id = 5179, appName = "Safari", bundleID = "com.apple.Safari", title = "B" })
    hsMock._focusedWindow = b
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.left, flags = {} })

    t.eq(#Tuck.store:railRecords("SCREEN-MAIN", 1, "left"), 2, "both Safari windows tracked independently")

    local recordA = Tuck.store:getByWindowID(4812)
    Tuck.windowManager:restore(recordA.tuckID)
    t.isFalse(a.isMinimized(), "window A restored")
    t.isTrue(b.isMinimized(), "window B (same app) remains tucked")
    t.eq(#Tuck.store:railRecords("SCREEN-MAIN", 1, "left"), 1, "rail reflowed down to one remaining card")

    Tuck:stop()
  end

  -- Zero-match search cancels and collapses without restoring anything.
  do
    local hsMock = freshHs()
    local Tuck = loadSpoon(hsMock)
    Tuck:start()

    local win = hsMock._makeWindow({ appName = "Safari", bundleID = "com.apple.Safari" })
    hsMock._focusedWindow = win
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.left, flags = {} })

    hsMock._pressHotkey({ "cmd", "shift" }, "t")
    hsMock._sendKeyDown({ keyCode = 99, flags = {}, chars = "z" })
    t.eq(Tuck.inputStateMachine:current(), "idle", "zero matches cancels back to idle")
    t.isTrue(win.isMinimized(), "no window was restored on a zero-match search")

    Tuck:stop()
  end

  -- Idempotent start(): calling twice must not register duplicate
  -- shortcuts (a duplicate tuck-shortcut binding would otherwise cause a
  -- single Fn+T press to advance the state machine twice).
  do
    local hsMock = freshHs()
    local Tuck = loadSpoon(hsMock)
    Tuck:start()
    Tuck:start()
    Tuck:start()

    local win = hsMock._makeWindow({ appName = "Safari", bundleID = "com.apple.Safari" })
    hsMock._focusedWindow = win
    hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    -- If the tuck shortcut had been bound three times, three calls to
    -- tuckShortcutPressed() would still just leave the state machine in
    -- waitingForDirection (its transition is idempotent-looking), so
    -- instead assert on the hotkey/eventtap registration counts
    -- directly.
    local fnBindingCount = #Tuck.shortcutManager.fnBindings
    t.eq(fnBindingCount, 1, "repeated start() must not accumulate duplicate fn-shortcut bindings")

    local hotkeyCount = 0
    for _, hk in ipairs(hsMock._hotkeys) do
      if not hk.deleted then
        hotkeyCount = hotkeyCount + 1
      end
    end
    t.eq(hotkeyCount, 1, "repeated start() must not accumulate duplicate hs.hotkey bindings")

    Tuck:stop()
  end

  -- stop() actually disables input: after stopping, the same keystrokes
  -- do nothing at all.
  do
    local hsMock = freshHs()
    local Tuck = loadSpoon(hsMock)
    Tuck:start()
    Tuck:stop()

    local win = hsMock._makeWindow({ appName = "Safari", bundleID = "com.apple.Safari" })
    hsMock._focusedWindow = win
    local consumed = hsMock._pressHotkey({}, "nonexistent") -- sanity: helper works
    t.isFalse(consumed)

    local firedFn = hsMock._sendKeyDown({ keyCode = hsMock.keycodes.map.t, flags = { fn = true } })
    t.isFalse(firedFn, "Fn+T does nothing after stop()")
    t.eq(Tuck.inputStateMachine:current(), "idle")
    t.isFalse(win.isMinimized(), "no tuck can happen once stopped")
  end

  -- Invalid configuration is rejected at :configure() time, before
  -- anything is built or started.
  do
    local hsMock = freshHs()
    local Tuck = loadSpoon(hsMock)
    local ok = pcall(function()
      Tuck:configure({ input = { directionTimeout = -5 } })
    end)
    t.isFalse(ok, "configure() must raise on an invalid merged configuration")
  end

  t.report("integration_spec")
  return #t.failures == 0
end

return run
