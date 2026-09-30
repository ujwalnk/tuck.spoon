--- Focus-history preservation: when the focused window is tucked, Tuck
-- must explicitly restore focus to the window that was genuinely focused
-- immediately before it -- never an arbitrary sibling window, never
-- "whatever macOS happens to pick", never chosen by application/bundle
-- identity. Exercises the real init.lua end to end (not a
-- reimplementation) against tests/mock_hs.lua, whose window.focus()
-- fires the same windowFocused event real Hammerspoon would, so this
-- validates the full tracker -> focus_history -> window.manager pipeline.

local t = require("tests.testkit")

local MODULES = {
  "config.defaults", "input.shortcut", "input.state", "input.matcher", "state.store",
  "state.persistence", "space.manager", "space.geometry", "card.icon", "card.preview",
  "card.manager", "card.renderer", "card.animator", "window.tracker", "window.manager",
  "window.focus_history",
}

local function boot(configure, prepare)
  package.loaded["tests.mock_hs"] = nil
  local hs = require("tests.mock_hs")
  if prepare then
    prepare(hs)
  end
  _G.hs = hs
  for _, m in ipairs(MODULES) do
    package.loaded[m] = nil
  end
  local Tuck = assert(loadfile("./init.lua"))():init()
  if configure then
    Tuck:configure(configure)
  end
  Tuck:start()
  return hs, Tuck
end

local K = { t = 17, left = 123 }
local function newWin(hs, app, extra)
  local o = { appName = app, bundleID = "com." .. app:lower() }
  for k, v in pairs(extra or {}) do
    o[k] = v
  end
  return hs._makeWindow(o)
end

--- Tuck the CURRENTLY focused window (as tracked by _userFocus) toward
-- `edge` via the real shortcut + arrow, exactly as a user would.
local function tuckCurrent(hs, edge)
  hs._sendKeyDown({ keyCode = K.t, flags = { fn = true } })
  hs._sendKeyDown({ keyCode = K[edge], flags = { fn = true } })
end

local function run()
  t.reset()

  -- ===== 1. Two different applications =====
  do
    local hs, Tuck = boot()
    local appB = newWin(hs, "Mail")
    local appA = newWin(hs, "Safari")
    hs._userFocus(appB)
    hs._userFocus(appA)
    tuckCurrent(hs, "left")

    t.isTrue(Tuck.store:getByWindowID(appA.id()) ~= nil, "App A is tucked")
    t.eq(hs._focusedWindow, appB, "App B (the previous window) is focused")
    t.eq(hs._focusLog[#hs._focusLog], appB.id(), "focus() was called on App B specifically")
    Tuck:stop()
  end

  -- ===== 2. Two windows of the same application =====
  do
    local hs, Tuck = boot()
    local safariB = newWin(hs, "Safari", { title = "B" })
    local safariA = newWin(hs, "Safari", { title = "A" })
    hs._userFocus(safariB)
    hs._userFocus(safariA)
    tuckCurrent(hs, "left")

    t.isTrue(Tuck.store:getByWindowID(safariA.id()) ~= nil, "Safari A is tucked")
    t.eq(hs._focusedWindow, safariB, "Safari B (same app, genuinely previous) is focused")
    t.eq(hs._focusLog[#hs._focusLog], safariB.id())
    Tuck:stop()
  end

  -- ===== 3. Three windows, same application: A=previous, B=current, C=another =====
  do
    local hs, Tuck = boot()
    local safariC = newWin(hs, "Safari", { title = "C" }) -- focused earliest, then abandoned
    local safariA = newWin(hs, "Safari", { title = "A" })
    local safariB = newWin(hs, "Safari", { title = "B" })
    hs._userFocus(safariC)
    hs._userFocus(safariA)
    hs._userFocus(safariB)
    tuckCurrent(hs, "left")

    t.isTrue(Tuck.store:getByWindowID(safariB.id()) ~= nil, "Safari B is tucked")
    t.eq(hs._focusedWindow, safariA, "Safari A (immediately previous) is focused")
    t.isFalse(hs._focusedWindow == safariC, "Safari C is never arbitrarily selected")
    t.eq(hs._focusLog[#hs._focusLog], safariA.id())
    Tuck:stop()
  end

  -- ===== 4. Multiple monitors: previous window on another screen =====
  do
    local hs, Tuck = boot(nil, function(h)
      h._addScreen("EXT", { x = -1920, y = 0, w = 1920, h = 1080 })
    end)
    local onExternal = newWin(hs, "Notes", { screen = hs._screens[2] })
    local onMain = newWin(hs, "Safari", { screen = hs._screens[1] })
    hs._userFocus(onExternal)
    hs._userFocus(onMain)
    tuckCurrent(hs, "left")

    t.isTrue(Tuck.store:getByWindowID(onMain.id()) ~= nil, "the main-screen window is tucked")
    t.eq(hs._focusedWindow, onExternal, "the exact previous window on the OTHER screen is focused")
    Tuck:stop()
  end

  -- ===== 5. Multiple Spaces: a tucked (hidden) window is never offered =====
  do
    local hs, Tuck = boot()
    -- Genuinely focus, then tuck, a window -- it must never be handed
    -- back out as a "previous" candidate for a later tuck while it
    -- remains hidden, even though it is still the most-recent entry
    -- ahead of being forgotten.
    local first = newWin(hs, "Preview")
    hs._userFocus(first)
    tuckCurrent(hs, "left") -- first is now tucked (hidden/minimized); history forgets it

    local second = newWin(hs, "Safari")
    hs._userFocus(second)
    tuckCurrent(hs, "left")
    -- No genuinely-focused, valid window exists before `second` (the
    -- tucked `first` must be skipped, not selected): focus is left alone.
    t.isTrue(Tuck.store:getByWindowID(second.id()) ~= nil, "second window is tucked")
    t.isFalse(hs._focusedWindow == first, "the still-hidden first window is never re-focused")
    Tuck:stop()
  end

  -- ===== 5b. Space-scoped: the previous window remains correct even when
  -- other tucked windows exist on a different Space =====
  do
    local hs, Tuck = boot()
    local other = newWin(hs, "Finder")
    hs._userFocus(other)
    local a = newWin(hs, "Preview")
    hs._userFocus(a)
    -- a Space-2 tuck happening in between must not corrupt the history
    -- used for the Space-1 tuck below.
    hs._activeSpaces["SCREEN-MAIN"] = 2
    local spaceTwoWin = newWin(hs, "Music")
    hs._userFocus(spaceTwoWin)
    tuckCurrent(hs, "left")
    hs._activeSpaces["SCREEN-MAIN"] = 1

    hs._userFocus(a)
    tuckCurrent(hs, "left")
    t.eq(hs._focusedWindow, other, "Space-1 tuck still restores its own genuine previous window")
    Tuck:stop()
  end

  -- ===== 6. No previous valid window: tucks cleanly, focuses nothing arbitrary =====
  do
    local hs, Tuck = boot()
    local only = newWin(hs, "Safari")
    hs._userFocus(only)
    local ok = pcall(tuckCurrent, hs, "left")
    t.isTrue(ok, "tucking the only-ever-focused window does not error")
    t.isTrue(Tuck.store:getByWindowID(only.id()) ~= nil, "it is still tucked")
    t.isTrue(hs._focusedWindow == only, "no arbitrary window is force-focused (macOS's own state is left alone)")

    -- A sibling of the SAME app existing (but never focused) must not be
    -- picked either.
    local sibling = newWin(hs, "Safari")
    local ok2 = pcall(tuckCurrent, hs, "left")
    t.isTrue(ok2)
    Tuck:stop()
  end

  -- ===== Focus history is not corrupted by Tuck's own internal focus
  -- calls (restore, and the auto-refocus itself) =====
  do
    local hs, Tuck = boot()
    local b = newWin(hs, "Mail")
    local a = newWin(hs, "Safari")
    hs._userFocus(b)
    hs._userFocus(a)
    tuckCurrent(hs, "left") -- a tucked, focus auto-restored to b (Tuck-internal)
    t.eq(hs._focusedWindow, b)

    -- Now genuinely focus a third window and tuck IT: the previous
    -- window must be b (the real prior state), not "a" resurrected by
    -- Tuck's own internal refocus being mistaken for a user action.
    local c = newWin(hs, "Notes")
    hs._userFocus(c)
    tuckCurrent(hs, "left")
    t.eq(hs._focusedWindow, b, "Tuck's own internal refocus of b was not itself recorded as a fresh user transition ahead of c")
    Tuck:stop()
  end

  -- ===== Restoring a tucked window also updates the history correctly =====
  do
    local hs, Tuck = boot()
    local b = newWin(hs, "Mail")
    local a = newWin(hs, "Safari")
    hs._userFocus(b)
    hs._userFocus(a)
    tuckCurrent(hs, "left") -- a tucked, b focused
    local recA = Tuck.store:getByWindowID(a.id())
    Tuck.windowManager:restore(recA.tuckID) -- a restored and focused again

    local c = newWin(hs, "Notes")
    hs._userFocus(c)
    tuckCurrent(hs, "left") -- tuck c: previous should be a (the restore genuinely re-focused it)
    t.eq(hs._focusedWindow, a, "restoring a window correctly re-enters it into focus history")
    Tuck:stop()
  end

  t.report("focus_restore_spec")
  return #t.failures == 0
end

return run
