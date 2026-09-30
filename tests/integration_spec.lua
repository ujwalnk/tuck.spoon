--- Integration tests: the REAL init.lua (and every module it wires up)
-- against tests/mock_hs.lua. Validates wiring and behaviour that the pure
-- unit tests cannot reach: the shared shortcut, hide/minimize mechanisms,
-- lifecycle handling, multi-window/Space/screen independence, search, card
-- states and animation. The mock encodes documented API signatures, not
-- real macOS behaviour -- see README "Manual validation".

local t = require("tests.testkit")

local MODULES = {
  "config.defaults", "input.shortcut", "input.state", "input.matcher", "state.store",
  "state.persistence", "space.manager", "space.geometry", "card.icon", "card.preview",
  "card.manager", "card.renderer", "card.animator", "window.tracker", "window.manager",
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

-- input helpers -------------------------------------------------------
local K = { t = 17, left = 123, right = 124, down = 125, up = 126, escape = 53 }
local function shortcut(hs) return hs._sendKeyDown({ keyCode = K.t, flags = { fn = true } }) end
local function arrow(hs, name) return hs._sendKeyDown({ keyCode = K[name], flags = { fn = true } }) end
local function esc(hs) return hs._sendKeyDown({ keyCode = K.escape, flags = {} }) end
local function letter(hs, ch) return hs._sendKeyDown({ keyCode = 99, flags = {}, chars = ch }) end

local function newWin(hs, app, extra)
  local o = { appName = app, bundleID = "com." .. app:lower() }
  for k, v in pairs(extra or {}) do o[k] = v end
  return hs._makeWindow(o)
end

local function tuck(hs, win, edge)
  hs._focusedWindow = win
  shortcut(hs)
  arrow(hs, edge)
end

local function settle(hs) hs._advance(0.6) end

local function frameOf(Tuck, win)
  local rec = Tuck.store:getByWindowID(win.id())
  return Tuck.cardManager.canvases[rec.tuckID].frame(), rec
end
local function canvasOf(Tuck, win)
  local rec = Tuck.store:getByWindowID(win.id())
  return Tuck.cardManager.canvases[rec.tuckID], rec
end

local function run()
  t.reset()

  -- ===== Shared shortcut: arrow tucks, all four edges =====
  do
    local hs, Tuck = boot()
    for _, edge in ipairs({ "left", "right", "up", "down" }) do
      local win = newWin(hs, "App" .. edge)
      hs._focusedWindow = win
      t.isTrue(shortcut(hs), "Fn+T consumed")
      t.eq(Tuck.inputStateMachine:current(), "waitingForCommand")
      arrow(hs, edge)
      t.eq(Tuck.inputStateMachine:current(), "idle")
      local rec = Tuck.store:getByWindowID(win.id())
      t.isTrue(rec ~= nil, edge .. " tuck creates a record")
      t.eq(rec.edge, ({ left = "left", right = "right", up = "top", down = "bottom" })[edge])
      t.isTrue(hs._apps[win.application().pid()] ~= nil)
      t.isFalse(win.isVisible(), edge .. " window is no longer visible")
    end
    Tuck:stop()
  end

  -- ===== Hiding mechanism: single-window app is HIDDEN (Cmd+H style), frame untouched =====
  do
    local hs, Tuck = boot()
    local win = newWin(hs, "Safari", { frame = { x = 50, y = 60, w = 700, h = 500 } })
    tuck(hs, win, "left")
    local rec = Tuck.store:getByWindowID(win.id())
    t.eq(rec.mechanism, "hide", "sole window uses app-level hide")
    t.isTrue(win.application()._hidden, "application is hidden")
    t.isFalse(win.isMinimized(), "not minimized")
    t.eq(win.frame().x, 50, "frame not moved")
    t.eq(win.frame().w, 700, "frame not resized")

    -- restore via card click: unhide, exact window front + focus, frame back
    win:setFrame({ x = 1, y = 2, w = 3, h = 4 }) -- drift while hidden
    canvasOf(Tuck, win)._fireMouse("mouseUp")
    t.isFalse(win.application()._hidden, "unhidden")
    t.isTrue(win.isVisible())
    t.eq(hs._focusLog[#hs._focusLog], win.id(), "exact window focused")
    t.eq(hs._raiseLog[#hs._raiseLog], win.id(), "exact window raised")
    t.eq(win.frame().x, 50, "original frame restored")
    t.eq(win.frame().h, 500)
    t.isNil(Tuck.store:getByWindowID(win.id()), "record removed")
    t.eq(next(Tuck.cardManager.canvases), nil, "card removed")
    Tuck:stop()
  end

  -- ===== Same-app windows stay independent (Safari A/B/C) =====
  do
    local hs, Tuck = boot()
    local a = newWin(hs, "Safari", { id = 4812, title = "A" })
    local b = newWin(hs, "Safari", { id = 5179, title = "B" })
    local c = newWin(hs, "Safari", { id = 6243, title = "C" })
    tuck(hs, a, "left")
    local ra = Tuck.store:getByWindowID(4812)
    t.eq(ra.mechanism, "minimize", "siblings visible -> per-window minimize, never app hide")
    t.isFalse(a.application()._hidden, "app NOT hidden: B and C stay visible")
    t.isTrue(b.isVisible() and c.isVisible(), "sibling windows untouched")
    tuck(hs, b, "left")
    tuck(hs, c, "right") -- last visible window, but app already has tuck records
    t.eq(Tuck.store:getByWindowID(6243).mechanism, "minimize", "never hide when another tuck exists")
    t.isFalse(c.application()._hidden)
    t.eq(#Tuck.store:railRecords("SCREEN-MAIN", 1, "left"), 2)
    t.eq(#Tuck.store:railRecords("SCREEN-MAIN", 1, "right"), 1)

    Tuck.windowManager:restore(Tuck.store:getByWindowID(5179).tuckID)
    t.isFalse(b.isMinimized(), "B restored")
    t.isTrue(a.isMinimized() and c.isMinimized(), "A and C remain tucked")
    t.eq(hs._focusLog[#hs._focusLog], 5179, "Safari B (not A/main window) focused")
    t.isTrue(Tuck.store:getByWindowID(4812) ~= nil and Tuck.store:getByWindowID(6243) ~= nil)
    Tuck:stop()
  end

  -- ===== A hidden window blocks a second hide (one hide-tuck per app) =====
  do
    local hs, Tuck = boot()
    local a = newWin(hs, "Safari")
    tuck(hs, a, "left")
    t.eq(Tuck.store:getByWindowID(a.id()).mechanism, "hide")
    local b = newWin(hs, "Safari")
    tuck(hs, b, "left")
    t.eq(Tuck.store:getByWindowID(b.id()).mechanism, "minimize", "second tuck of a hidden app falls back to minimize")
    -- restoring b (minimized) must not unhide the app nor touch a
    Tuck.windowManager:restore(Tuck.store:getByWindowID(b.id()).tuckID)
    t.isTrue(a.application()._hidden, "app stays hidden while A is tucked")
    t.isTrue(Tuck.store:getByWindowID(a.id()) ~= nil)
    Tuck:stop()
  end

  -- ===== Esc / timeout cancel; arrows never restore =====
  do
    local hs, Tuck = boot()
    local win = newWin(hs, "Slack")
    hs._focusedWindow = win
    shortcut(hs)
    esc(hs)
    t.eq(Tuck.inputStateMachine:current(), "idle")
    t.isTrue(win.isVisible(), "Esc tucks nothing")

    shortcut(hs)
    hs._fireAllTimers()
    t.eq(Tuck.inputStateMachine:current(), "idle", "timeout cancels")
    t.isTrue(win.isVisible())

    tuck(hs, win, "left")
    local other = newWin(hs, "Terminal")
    hs._focusedWindow = other
    shortcut(hs); arrow(hs, "left"); -- tuck Terminal too
    -- an arrow after the shortcut can never restore Slack
    t.isTrue(Tuck.store:getByWindowID(win.id()) ~= nil, "arrows never restore")
    Tuck:stop()
  end

  -- ===== Search: unique letter restores, multiple expand, narrowing =====
  do
    local hs, Tuck = boot()
    local safari = newWin(hs, "Safari")
    local slack = newWin(hs, "Slack")
    local spotify = newWin(hs, "Spotify")
    local term = newWin(hs, "Terminal")
    for _, w in ipairs({ safari, slack, spotify, term }) do tuck(hs, w, "left") end
    local front = newWin(hs, "Finder")
    hs._focusedWindow = front
    settle(hs)

    -- unique first letter
    shortcut(hs)
    letter(hs, "t")
    t.eq(Tuck.inputStateMachine:current(), "idle")
    t.isTrue(term.isVisible(), "Terminal restored")
    t.isTrue(Tuck.store:getByWindowID(safari.id()) ~= nil)

    -- multiple matches expand; more letters narrow
    hs._focusedWindow = front
    shortcut(hs)
    letter(hs, "s")
    t.eq(Tuck.inputStateMachine:current(), "waitingForCommand", "S keeps the search alive")
    local expanded = 0
    for _, w in ipairs({ safari, slack, spotify }) do
      local rec = Tuck.store:getByWindowID(w.id())
      if Tuck.cardManager.searchMatched[rec.tuckID] then expanded = expanded + 1 end
    end
    t.eq(expanded, 3, "Safari, Slack and Spotify all expand")
    settle(hs)
    local f = frameOf(Tuck, safari)
    t.eq(f.w, 220, "matched card reached the expanded size")
    letter(hs, "a")
    t.eq(Tuck.inputStateMachine:current(), "idle")
    t.isTrue(safari.isVisible(), "SA restores Safari immediately")
    t.isTrue(Tuck.store:getByWindowID(slack.id()) ~= nil)
    t.eq(next(Tuck.cardManager.searchMatched), nil, "search expansion cleared after restore")
    Tuck:stop()
  end

  -- ===== Search: zero match, Esc, timeout, timer reset, arrows ignored =====
  do
    local hs, Tuck = boot()
    local a = newWin(hs, "Safari")
    local b = newWin(hs, "Slack")
    tuck(hs, a, "left"); tuck(hs, b, "left")
    hs._focusedWindow = newWin(hs, "Finder")

    shortcut(hs); letter(hs, "z")
    t.eq(Tuck.inputStateMachine:current(), "idle", "zero matches cancel")
    t.isFalse(a.isVisible() and b.isVisible(), "nothing restored on zero matches")

    shortcut(hs); letter(hs, "s")
    esc(hs)
    t.eq(Tuck.inputStateMachine:current(), "idle")
    t.eq(next(Tuck.cardManager.searchMatched), nil, "Esc collapses expanded cards")

    shortcut(hs)
    letter(hs, "s")
    hs._focusedWindow = newWin(hs, "Preview")
    arrow(hs, "left")
    t.eq(Tuck.inputStateMachine:current(), "waitingForCommand", "arrow ignored while searching")
    t.eq(Tuck.store:getByWindowID(hs._focusedWindow.id()), nil, "arrow did not tuck during a search")

    -- timeout resets after each accepted character
    local function liveTimers()
      local n, handles = 0, {}
      for _, h in ipairs(hs._pendingTimers) do
        if not h.repeating and not h.stopped and h.seconds == 1.5 then n = n + 1; handles[#handles + 1] = h end
      end
      return n, handles
    end
    esc(hs)
    shortcut(hs)
    local _, h1 = liveTimers()
    letter(hs, "s")
    local n2, h2 = liveTimers()
    t.eq(n2, 1, "exactly one live command timer")
    t.isTrue(h1[1].stopped, "previous timer cancelled when a letter is accepted")
    hs._fireAllTimers()
    t.eq(Tuck.inputStateMachine:current(), "idle", "timeout cancels the search")
    Tuck:stop()
  end

  -- ===== Manual unhide / unminimize, destroy, app quit =====
  do
    local hs, Tuck = boot()
    local win = newWin(hs, "Mail")
    tuck(hs, win, "left")
    local rec = Tuck.store:getByWindowID(win.id())
    win.application().unhide() -- the user revealed the app themselves
    t.isNil(Tuck.store:getByWindowID(win.id()), "manual unhide removes the tuck")
    t.isNil(Tuck.cardManager.canvases[rec.tuckID], "and its card")
    t.isFalse(win.application()._hidden, "Tuck does not re-hide it")

    -- internal restore does not double-clean
    local w2 = newWin(hs, "Notes")
    tuck(hs, w2, "left")
    t.isTrue(Tuck.windowManager:restore(Tuck.store:getByWindowID(w2.id()).tuckID))
    t.isNil(next(Tuck.windowManager.hideRestoring), "guard consumed by the unhide event")

    -- a late unhide event (after restore() already removed the record) still consumes the guard
    do
      local w3 = newWin(hs, "Numbers")
      tuck(hs, w3, "left")
      local key = w3.application().pid()
      Tuck.windowManager.hideRestoring[key] = true
      Tuck.windowManager:handleAppUnhidden(w3.application())
      t.isNil(Tuck.windowManager.hideRestoring[key], "guard cleared even when no record remains")
      t.isTrue(Tuck.store:getByWindowID(w3.id()) ~= nil, "and the still-tucked window is untouched")
      Tuck.windowManager:restore(Tuck.store:getByWindowID(w3.id()).tuckID)
    end

    -- manual unminimize of a minimize-tucked window
    local a = newWin(hs, "Preview"); local b = newWin(hs, "Preview")
    tuck(hs, a, "left")
    t.eq(Tuck.store:getByWindowID(a.id()).mechanism, "minimize")
    a.unminimize()
    t.isNil(Tuck.store:getByWindowID(a.id()), "manual unminimize removes the tuck")

    -- destroyed while hidden
    local d = newWin(hs, "Pages")
    tuck(hs, d, "left")
    local drec = Tuck.store:getByWindowID(d.id())
    d._destroy()
    t.isNil(Tuck.store:getByWindowID(d.id()))
    t.isNil(Tuck.cardManager.canvases[drec.tuckID], "destroyed hidden window leaves no card")

    -- application quits while a window is tucked
    local q = newWin(hs, "Keynote")
    tuck(hs, q, "left")
    hs._terminateApp(q.application())
    t.eq(#Tuck.store:allWindows(), 0, "quit app leaves no stale record")
    t.eq(next(Tuck.cardManager.canvases), nil, "or stale card")
    Tuck:stop()
  end

  -- ===== All Spaces windows are rejected =====
  do
    local hs, Tuck = boot(nil, function(h)
      h.spaces.windowSpaces = function() return { 1, 2, 3 } end
    end)
    local win = newWin(hs, "Weird")
    tuck(hs, win, "left")
    t.isTrue(win.isVisible(), "All-Spaces window not hidden")
    t.isFalse(win.application()._hidden)
    t.eq(#Tuck.store:allWindows(), 0)
    Tuck:stop()
  end

  -- ===== Screens / Spaces: same app stays distinct; scope-aware search =====
  do
    local hs, Tuck = boot({ search = { scope = "space" } }, function(h)
      h._addScreen("EXT", { x = -1920, y = 0, w = 1920, h = 1080 })
    end)
    local ext = hs._screens[2]
    local a = newWin(hs, "Safari", { screen = hs._screens[1] })
    local b = newWin(hs, "Safari", { screen = ext })
    tuck(hs, a, "left"); tuck(hs, b, "left")
    t.eq(#Tuck.store:railRecords("SCREEN-MAIN", 1, "left"), 1)
    t.eq(#Tuck.store:railRecords("EXT", 1, "left"), 1, "same app, other screen = separate shelf")
    local fb = frameOf(Tuck, b)
    t.eq(fb.x + fb.w, -1920 + 8, "negative-coordinate screen parks at its own edge")

    -- Space 2 on the main screen
    hs._activeSpaces["SCREEN-MAIN"] = 2
    local c = newWin(hs, "Safari", { screen = hs._screens[1] })
    tuck(hs, c, "left")
    t.eq(Tuck.store:getByWindowID(c.id()).spaceID, 2)
    t.eq(#Tuck.store:railRecords("SCREEN-MAIN", 2, "left"), 1)
    hs._activeSpaces["SCREEN-MAIN"] = 1

    -- space scope: both Space-1 cards (both screens) match; Space-2 card does not
    local finder = newWin(hs, "Finder", { screen = hs._screens[1] })
    hs._focusedWindow = finder
    shortcut(hs); letter(hs, "s")
    local matched = 0
    for _ in pairs(Tuck.cardManager.searchMatched) do matched = matched + 1 end
    t.eq(matched, 2, "space scope finds cards on both screens of the Space")
    t.isNil(Tuck.cardManager.searchMatched[Tuck.store:getByWindowID(c.id()).tuckID], "other Space excluded")
    esc(hs)
    Tuck:stop()

    local hs2, Tuck2 = boot({ search = { scope = "screenAndSpace" } }, function(h)
      h._addScreen("EXT", { x = -1920, y = 0, w = 1920, h = 1080 })
    end)
    local a2 = newWin(hs2, "Safari", { screen = hs2._screens[1] })
    local b2 = newWin(hs2, "Safari", { screen = hs2._screens[2] })
    tuck(hs2, a2, "left"); tuck(hs2, b2, "left")
    hs2._focusedWindow = newWin(hs2, "Finder", { screen = hs2._screens[1] })
    shortcut(hs2); letter(hs2, "s")
    t.eq(Tuck2.inputStateMachine:current(), "idle", "screenAndSpace sees only the current screen: unique match restores")
    t.isTrue(a2.isVisible() and not b2.isVisible(), "only the current-screen Safari restored")
    Tuck2:stop()
  end

  -- ===== Card states: parked / edge reveal / hover, all four edges =====
  do
    local hs, Tuck = boot()
    local l = newWin(hs, "Left"); local r = newWin(hs, "Right")
    local tp = newWin(hs, "Top"); local bt = newWin(hs, "Bottom")
    tuck(hs, l, "left"); tuck(hs, r, "right"); tuck(hs, tp, "up"); tuck(hs, bt, "down")

    local fl = frameOf(Tuck, l)
    t.eq(fl.w, 72, "parking never resizes the card")
    t.eq(fl.x + fl.w, 8, "left card parked: only peekSize visible")
    local fr = frameOf(Tuck, r)
    t.eq(fr.x, 1440 - 8, "right card parked: only peekSize visible")
    local ft = frameOf(Tuck, tp)
    t.eq(ft.y, 8, "top rail keeps the classic fully-visible position")
    local fb = frameOf(Tuck, bt)
    t.eq(fb.y + fb.h, 900 - 8)
    t.isNil(Tuck.cardManager.railZones["SCREEN-MAIN|1|top"], "no edge trigger on non-peek rails")

    -- pointer approaches the left edge (in the strip, but not over the card sliver)
    local lrec = Tuck.store:getByWindowID(l.id())
    local canvasL = canvasOf(Tuck, l)
    local cy = fl.y + fl.h / 2
    hs._sendMouseMove(50, cy + 200) -- outside the rail span: nothing
    settle(hs)
    t.eq(frameOf(Tuck, l).x + 72, 8, "pointer away from the strip does nothing")
    hs._sendMouseMove(50, cy)
    settle(hs)
    local rv = frameOf(Tuck, l)
    t.eq(rv.x + rv.w, 40, "edge reveal exposes edgeRevealSize")
    t.eq(rv.y, fl.y, "reveal keeps the rail position")
    t.eq(rv.w, 72)
    t.isTrue(Tuck.cardManager.railRevealed["SCREEN-MAIN|1|left"], "rail revealed")
    -- right rail unaffected
    t.eq(frameOf(Tuck, r).x, 1440 - 8)

    -- hover the card: expands inward, anchored at the boundary
    canvasL._fireMouse("mouseEnter")
    settle(hs)
    local hv = frameOf(Tuck, l)
    t.eq(hv.w, 220); t.eq(hv.h, 160)
    t.eq(hv.x, 8, "expanded card anchored at the left boundary and grown inward")
    t.isTrue(hv.x >= 0 and hv.y >= 0 and hv.x + hv.w <= 1440 and hv.y + hv.h <= 900, "stays inside the screen")

    -- unhover with the pointer still in the strip: back to the reveal depth (no snap out)
    canvasL._fireMouse("mouseExit")
    settle(hs)
    local back = frameOf(Tuck, l)
    t.eq(back.x + back.w, 40, "returns to edge reveal while the pointer stays near the edge")
    -- pointer leaves: after the grace delay the rail parks again
    hs._sendMouseMove(700, 400)
    settle(hs)
    t.eq(frameOf(Tuck, l).x + 72, 40, "not retracted before the grace delay")
    hs._fireAllTimers()
    settle(hs)
    t.eq(frameOf(Tuck, l).x + 72, 8, "parked again after the grace delay")
    t.isNil(Tuck.cardManager.railRevealed["SCREEN-MAIN|1|left"])
    t.eq(hs._activeRepeating(), 0, "animation ticker stopped when idle")
    Tuck:stop()
  end

  -- ===== Shared shortcut reveals every tucked card, then releases =====
  do
    local hs, Tuck = boot()
    local a = newWin(hs, "Alpha"); local b = newWin(hs, "Beta")
    tuck(hs, a, "left"); tuck(hs, b, "left")
    settle(hs)
    local fa, fb = frameOf(Tuck, a), frameOf(Tuck, b)
    t.eq(fa.x + fa.w, 8, "parked before the shortcut")
    t.eq(fb.x + fb.w, 8)

    hs._focusedWindow = newWin(hs, "Finder")
    shortcut(hs)
    settle(hs)
    t.isTrue(Tuck.cardManager.commandRevealActive)
    fa, fb = frameOf(Tuck, a), frameOf(Tuck, b)
    t.eq(fa.x, 8, "shortcut brings every tucked card fully inside the screen")
    t.eq(fb.x, 8)
    t.eq(fa.w, 72, "still the collapsed size, not expanded")

    -- concludes on Esc, and rails return to parked
    esc(hs)
    settle(hs)
    t.isFalse(Tuck.cardManager.commandRevealActive)
    fa = frameOf(Tuck, a)
    t.eq(fa.x + fa.w, 8, "parked again once the command ends")

    -- also concludes on a completed tuck
    hs._focusedWindow = newWin(hs, "Preview")
    shortcut(hs)
    t.isTrue(Tuck.cardManager.commandRevealActive)
    arrow(hs, "left")
    t.isFalse(Tuck.cardManager.commandRevealActive, "ends the moment a tuck completes")

    -- and on a completed restore (unique-letter search)
    hs._focusedWindow = newWin(hs, "Finder2")
    shortcut(hs)
    letter(hs, "a") -- unique match: Alpha
    t.isFalse(Tuck.cardManager.commandRevealActive, "ends the moment a restore completes")

    -- reveal-all does not fight an already-hovered card's full expansion
    local c = newWin(hs, "Gamma")
    tuck(hs, c, "left")
    local cc = canvasOf(Tuck, c)
    cc._fireMouse("mouseEnter")
    settle(hs)
    t.eq(cc.frame().w, 220, "hover already expanded")
    hs._focusedWindow = newWin(hs, "Finder3")
    shortcut(hs)
    settle(hs)
    t.eq(cc.frame().w, 220, "reveal-all does not shrink an expanded card")
    esc(hs)
    Tuck:stop()
  end

  -- ===== Retract grace: leaving and re-entering must not flicker =====
  do
    local hs, Tuck = boot()
    local a = newWin(hs, "Alpha")
    tuck(hs, a, "left")
    local f = frameOf(Tuck, a)
    local cy = f.y + f.h / 2
    hs._sendMouseMove(50, cy)
    settle(hs)
    t.eq(frameOf(Tuck, a).x + 72, 40, "revealed")
    hs._sendMouseMove(700, cy) -- leave
    local retract
    for _, h in ipairs(hs._pendingTimers) do
      if not h.repeating and not h.stopped and h.seconds == Tuck.config.card.revealGraceDelay then retract = h end
    end
    t.isTrue(retract ~= nil, "a retract timer with the configured grace delay is pending")
    hs._sendMouseMove(50, cy) -- come back before it fires
    t.isTrue(retract.stopped, "re-entry cancels the pending retract")
    hs._fireAllTimers()
    settle(hs)
    t.eq(frameOf(Tuck, a).x + 72, 40, "no snap back out while the pointer is still near the edge")
    Tuck:stop()
  end

  -- ===== Neighbours do not jump; hover + search coexist; search reveals matched cards =====
  do
    local hs, Tuck = boot()
    local a = newWin(hs, "Alpha"); local b = newWin(hs, "Beta")
    tuck(hs, a, "left"); tuck(hs, b, "left")
    settle(hs)
    local ca, cb = canvasOf(Tuck, a), canvasOf(Tuck, b)
    local bBefore = #cb._writes()
    ca._fireMouse("mouseEnter")
    settle(hs)
    t.eq(cb.frame().x + cb.frame().w, 40, "neighbour follows only the shared rail reveal")
    local bx = cb.frame().x
    local ay = ca.frame().y
    ca._fireMouse("mouseExit")
    settle(hs)
    t.eq(cb.frame().x, bx, "neighbour did not jump from hovering another card")
    -- hovered AND search-matched: stays expanded until both end
    hs._focusedWindow = newWin(hs, "Finder")
    ca._fireMouse("mouseEnter")
    shortcut(hs); letter(hs, "a")
    -- unique match restores Alpha; use two-match query instead
    Tuck:stop()

    local hs2, T2 = boot()
    local s1 = newWin(hs2, "Sa"); local s2 = newWin(hs2, "Sb"); local o = newWin(hs2, "Other")
    tuck(hs2, s1, "left"); tuck(hs2, s2, "left"); tuck(hs2, o, "left")
    hs2._focusedWindow = newWin(hs2, "Finder")
    canvasOf(T2, s1)._fireMouse("mouseEnter")
    shortcut(hs2); letter(hs2, "s")
    settle(hs2)
    t.eq(canvasOf(T2, s1).frame().w, 220); t.eq(canvasOf(T2, s2).frame().w, 220)
    t.eq(canvasOf(T2, o).frame().w, 72, "non-matching card stays compact")
    esc(hs2)
    settle(hs2)
    t.eq(canvasOf(T2, s1).frame().w, 220, "still hovered -> stays expanded after the search ends")
    t.eq(canvasOf(T2, s2).frame().w, 72, "search-only card collapses")
    canvasOf(T2, s1)._fireMouse("mouseExit")
    settle(hs2)
    t.eq(canvasOf(T2, s1).frame().w, 72)
    T2:stop()
  end

  -- ===== Animation stability: rapid in/out and card-to-card, no leaks =====
  do
    local hs, Tuck = boot()
    local a = newWin(hs, "Alpha"); local b = newWin(hs, "Beta")
    tuck(hs, a, "left"); tuck(hs, b, "left")
    settle(hs)
    local ca, cb = canvasOf(Tuck, a), canvasOf(Tuck, b)
    for i = 1, 40 do
      ca._fireMouse("mouseEnter"); hs._advance(0.017)
      ca._fireMouse("mouseExit"); cb._fireMouse("mouseEnter"); hs._advance(0.017)
      cb._fireMouse("mouseExit"); hs._advance(0.01)
    end
    t.isTrue(Tuck.cardManager.animator:activeCount() <= 2, "no animation pile-up")
    hs._sendMouseMove(700, 400)
    hs._fireAllTimers()
    settle(hs)
    -- lands exactly on the parked frames
    t.eq(ca.frame().x + ca.frame().w, 8); t.eq(cb.frame().x + cb.frame().w, 8)
    t.eq(ca.frame().w, 72); t.eq(cb.frame().w, 72)
    t.eq(hs._activeRepeating(), 0, "ticker stopped after the animations finished")
    -- every written frame stays within sane bounds (no wild overshoot / oscillation)
    for _, f in ipairs(ca._writes()) do
      t.isTrue(f.x >= -80 and f.x <= 20 and f.w >= 72 - 1e-6 and f.w <= 220 + 1e-6, "frame within bounds")
    end
    Tuck:stop()
    t.eq(hs._activeRepeating(), 0)
    t.eq(hs._runningTaps(5), 0, "mouse tap released")
  end

  -- ===== start/stop/reload idempotency, no duplicate taps/hotkeys =====
  do
    local hs, Tuck = boot()
    Tuck:start(); Tuck:start()
    t.eq(#Tuck.shortcutManager.fnBindings, 1, "one shortcut binding")
    t.eq(hs._runningTaps(10), 2, "shortcut tap + input tap only")
    local win = newWin(hs, "Safari")
    tuck(hs, win, "left")
    t.eq(hs._runningTaps(5), 1, "one mouse-move tap while a peek rail has cards")
    Tuck:stop(); Tuck:stop()
    t.eq(hs._runningTaps(10), 0)
    t.eq(hs._runningTaps(5), 0)
    t.isFalse(shortcut(hs), "Fn+T does nothing after stop()")
    t.eq(next(Tuck.cardManager.canvases), nil, "stop() removes every card")
    t.eq(#hs._wfSubscribers, 0, "window filter released")
    local live = 0
    for _, w in ipairs(hs._appWatchers) do if w.running then live = live + 1 end end
    t.eq(live, 0, "application watcher released")
  end

  -- ===== configuration =====
  do
    local hs, Tuck = boot()
    t.isFalse(pcall(function() Tuck:configure({ input = { commandTimeout = -5 } }) end))
    Tuck:stop()
    -- custom shortcut works, old separate shortcut is ignored
    local hs2, T2 = boot({ shortcuts = { tuck = { mods = { "fn" }, key = "s" }, untuck = { mods = { "cmd" }, key = "t" } } })
    local hkCount = 0
    for _, hk in ipairs(hs2._hotkeys) do if not hk.deleted then hkCount = hkCount + 1 end end
    t.eq(hkCount, 0, "no separate untuck hotkey is registered")
    T2:stop()
  end

  t.report("integration_spec")
  return #t.failures == 0
end

return run
