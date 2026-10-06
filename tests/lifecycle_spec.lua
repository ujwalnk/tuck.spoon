--- Resource lifecycle: what exists while idle, in command mode, while
-- tucked, while animating, while a write is pending, and after the last
-- tuck. Also: event-driven hover, unrelated-window integrity, and
-- garbage-collectability. These tests assert OWNERSHIP and TEARDOWN, not
-- just visible output.

local t = require("tests.testkit")
local H = require("tests.harness")

local function expectIdle(r, label)
  t.eq(r.hotkeys, 1, label .. ": the activation hotkey is the only permanent resource")
  t.eq(r.keyTaps, 0, label .. ": no keyboard eventtap")
  t.eq(r.mouseTaps, 0, label .. ": no mouse eventtap")
  t.eq(r.repeatingTimers, 0, label .. ": no repeating timer / animation ticker")
  t.eq(r.oneShotTimers, 0, label .. ": no pending one-shot timer")
  t.eq(r.windowFilterSubs, 0, label .. ": no window filter")
  t.eq(r.appWatchers, 0, label .. ": no application watcher")
  t.eq(r.screenWatchers, 0, label .. ": no screen watcher")
  t.eq(r.spaceWatchers, 0, label .. ": no Space watcher")
  t.eq(r.cards, 0, label .. ": no card canvas")
  t.eq(r.sensors, 0, label .. ": no hover/zone canvas")
end

local function run()
  t.reset()

  -- ===== A. completely idle =====
  do
    local hs, Tuck = H.boot()
    expectIdle(H.resources(hs), "idle at start")
    t.eq(hs._enumerations or 0, 0, "startup enumerates no windows")
    t.eq(hs._filtersCreated or 0, 0, "startup creates no window filter")
    hs._advance(30)
    hs._fireAllTimers()
    expectIdle(H.resources(hs), "idle after 30s")
    t.eq(Tuck.iconManager.cache and next(Tuck.iconManager.cache), nil, "no icon cache")
    t.eq(Tuck.persistence.timer, nil, "no persistence timer")
    Tuck:stop()
    t.eq(H.resources(hs).hotkeys, 0, "stop() removes even the hotkey")
  end

  -- ===== B. command mode: temporary resources appear and vanish =====
  do
    local hs, Tuck = H.boot()
    local win = H.newWin(hs, "Safari", { title = "S" })
    hs._userFocus(win)

    -- Esc cancels
    H.shortcut(hs)
    local r = H.resources(hs)
    t.eq(r.keyTaps, 1, "command mode: exactly one temporary keyboard tap")
    t.eq(r.oneShotTimers, 1, "command mode: exactly the timeout timer")
    H.shortcut(hs) -- pressing again must not stack taps/timers
    r = H.resources(hs)
    t.eq(r.keyTaps, 1, "re-pressing the shortcut keeps a single tap")
    t.isTrue(r.oneShotTimers <= 2 and Tuck.commandTimer ~= nil)
    H.esc(hs)
    expectIdle(H.resources(hs), "after Esc")
    t.isNil(Tuck.commandTimer); t.isNil(Tuck.inputTap)

    -- timeout cancels
    H.shortcut(hs)
    t.eq(H.resources(hs).keyTaps, 1)
    hs._fireAllTimers()
    expectIdle(H.resources(hs), "after timeout")
    t.isFalse(Tuck.inputStateMachine:current() ~= "idle", "state machine back to idle")

    -- the tap ignores everything but the command keys, and is gone after use
    H.shortcut(hs)
    t.isFalse(hs._sendKeyDown({ keyCode = 99, flags = { cmd = true }, chars = "c" }), "unrelated shortcut passes through")
    t.isTrue(H.arrow(hs, "left"), "arrow consumed while in command mode")
    r = H.resources(hs)
    t.eq(r.keyTaps, 0, "tap destroyed the moment the tuck resolved the command")
    t.isNil(Tuck.commandTimer, "command timer destroyed")
    t.isFalse(H.arrow(hs, "left"), "arrows are not intercepted outside command mode")

    -- search path: restart keeps one tap; resolution tears it down
    local w2 = H.newWin(hs, "Safari", { title = "Two" })
    local w3 = H.newWin(hs, "Sandbox", { title = "Three" })
    H.tuck(hs, w2, "left"); H.tuck(hs, w3, "left")
    hs._focusedWindow = win
    H.shortcut(hs); H.letter(hs, "s")
    t.eq(H.resources(hs).keyTaps, 1, "still searching: one tap")
    H.letter(hs, "a") -- "SA": matches Safari(1)? Sandbox(1)? -> narrows
    H.letter(hs, "n") -- "SAN" -> Sandbox only -> restore
    t.eq(H.resources(hs).keyTaps, 0, "restore resolved the command: tap gone")
    t.isNil(Tuck.commandTimer)
    Tuck:stop()
  end

  -- ===== C. tucked-but-idle: watchers exist, nothing polls =====
  do
    local hs, Tuck = H.boot()
    local a = H.newWin(hs, "Safari", { title = "A" }); local b = H.newWin(hs, "Mail", { title = "B" })
    hs._userFocus(b); hs._userFocus(a)
    t.eq(hs._filtersCreated or 0, 0)
    H.tuck(hs, a, "left")
    t.eq(hs._filtersCreated, 1, "the window filter was created lazily, by the first tuck")
    H.settle(hs); hs._fireAllTimers()
    local r = H.resources(hs)
    t.eq(r.hotkeys, 1); t.eq(r.keyTaps, 0); t.eq(r.mouseTaps, 0)
    t.eq(r.repeatingTimers, 0, "no ticker once animation finished")
    t.eq(r.oneShotTimers, 0, "no persistence/guard timer left")
    t.eq(r.windowFilterSubs, 3, "unminimized + destroyed + focused only")
    t.eq(r.appWatchers, 1); t.eq(r.screenWatchers, 1); t.eq(r.spaceWatchers, 1)
    t.eq(r.cards, 1, "one visual card")
    t.eq(r.sensors, 2, "one card sensor + one edge zone")

    -- a long quiet period does nothing at all
    local canvas = H.canvasOf(Tuck, a)
    local writes = #canvas._writes()
    local enum, filters = hs._enumerations or 0, hs._filtersCreated
    for _ = 1, 10 do hs._advance(10) end
    t.eq(#canvas._writes(), writes, "no frame writes while idle")
    t.eq(hs._enumerations or 0, enum, "no window enumeration while idle")
    t.eq(hs._filtersCreated, filters)
    t.eq(H.resources(hs).oneShotTimers, 0)

    -- a second tuck reuses the single filter / watchers
    local c = H.newWin(hs, "Notes", { title = "C" })
    H.tuck(hs, c, "right")
    t.eq(hs._filtersCreated, 1, "no second window filter")
    t.eq(H.resources(hs).windowFilterSubs, 3)
    t.eq(H.resources(hs).appWatchers, 1)
    Tuck:stop()
  end

  -- ===== D. animation infrastructure exists only while animating =====
  do
    local hs, Tuck = H.boot()
    local a = H.newWin(hs, "Safari", { title = "A" })
    H.tuck(hs, a, "left"); H.settle(hs); hs._fireAllTimers()
    t.eq(H.resources(hs).repeatingTimers, 0)
    local y = H.canvasOf(Tuck, a).frame().y + 36
    hs._sendMouseMove(50, y) -- edge zone
    t.eq(H.resources(hs).repeatingTimers, 1, "ticker exists while animating")
    t.isTrue(Tuck.cardManager.animator.ticker ~= nil)
    H.settle(hs)
    t.eq(H.resources(hs).repeatingTimers, 0, "ticker destroyed when the animation finished")
    t.isNil(Tuck.cardManager.animator.ticker)
    Tuck:stop()
  end

  -- ===== E. persistence timer: only while a write is pending =====
  do
    local hs, Tuck, dir = H.boot()
    t.isNil(Tuck.persistence.timer)
    local a = H.newWin(hs, "Safari", { title = "A" }); local b = H.newWin(hs, "Mail", { title = "B" })
    H.tuck(hs, a, "left"); H.tuck(hs, b, "right")
    t.isTrue(Tuck.persistence.timer ~= nil, "a write is pending")
    local pending = 0
    for _, h in ipairs(hs._pendingTimers) do
      if not h.stopped and h.seconds == Tuck.config.persistence.debounce then pending = pending + 1 end
    end
    t.eq(pending, 1, "two state changes coalesced into ONE timer")
    hs._fireAllTimers()
    t.isNil(Tuck.persistence.timer, "timer gone after the write")
    t.isTrue(H.readFile(dir .. "/state.json") ~= nil)
    -- unrelated pointer activity never schedules a write
    local before = Tuck.persistence.lastDocument
    hs._sendMouseMove(50, H.canvasOf(Tuck, a).frame().y + 36); H.settle(hs)
    hs._sendMouseMove(700, 400); hs._fireAllTimers(); H.settle(hs)
    t.isNil(Tuck.persistence.timer, "hover does not touch persistence")
    t.eq(Tuck.persistence.lastDocument, before)
    Tuck:stop()
  end

  -- ===== F. last tuck removed -> back to idle, everything releasable =====
  do
    local hs, Tuck = H.boot({ prepare = function(h) h.screenRecordingState = function() return true end end })
    local a = H.newWin(hs, "Safari", { title = "A" }); local b = H.newWin(hs, "Mail", { title = "B" })
    H.tuck(hs, a, "left"); H.tuck(hs, b, "up")
    local weak = setmetatable({}, { __mode = "v" })
    weak.recA = Tuck.store:getByWindowID(a.id())
    weak.thumbA = weak.recA.thumbnail
    t.isTrue(weak.thumbA ~= nil)
    hs._sendMouseMove(50, H.canvasOf(Tuck, a).frame().y + 36); H.settle(hs) -- hover/reveal state
    H.click(Tuck, a)
    H.settle(hs); hs._fireAllTimers()
    local r = H.resources(hs)
    t.eq(r.windowFilterSubs, 3, "one tuck left: watchers still needed")
    H.click(Tuck, b)
    H.settle(hs); hs._fireAllTimers()
    expectIdle(H.resources(hs), "after the last tuck")
    local cm = Tuck.cardManager
    t.eq(H.countKeys(cm.canvases), 0); t.eq(H.countKeys(cm.hitCanvases), 0)
    t.eq(H.countKeys(cm.railZones), 0); t.eq(H.countKeys(cm.railInfo), 0)
    t.eq(H.countKeys(cm.restFrames), 0); t.eq(H.countKeys(cm.anchorFrames), 0)
    t.eq(H.countKeys(cm.hovered), 0); t.eq(H.countKeys(cm.retractTimers), 0)
    t.eq(Tuck.store:count(), 0)
    t.eq(next(Tuck.iconManager.cache), nil, "icon cache released")
    t.eq(#Tuck.focusHistory:snapshot(), 0, "focus history released")
    t.isNil(next(Tuck.windowManager.restoring))
    -- nothing in Tuck still references the removed record or its preview
    a = nil
    collectgarbage(); collectgarbage()
    t.isNil(weak.recA, "the removed tuck record is garbage-collectable")
    t.isNil(weak.thumbA, "its thumbnail is garbage-collectable")
    Tuck:stop()
  end

  -- ===== G. hover is event driven; the visible card has no mouse hooks =====
  do
    local hs, Tuck = H.boot()
    local a = H.newWin(hs, "Alpha", { title = "A" }); local b = H.newWin(hs, "Beta", { title = "B" })
    H.tuck(hs, a, "left"); H.tuck(hs, b, "left"); H.settle(hs)
    local cm = Tuck.cardManager
    local cardCanvas, recA = H.canvasOf(Tuck, a)
    t.isFalse(cardCanvas._hasMouseCallback(), "visible card is click-through")
    t.eq(hs._runningTaps(5), 0, "no mouse eventtap")
    local hitA = cm.hitCanvases[recA.tuckID]
    local zone
    for _, z in pairs(cm.railZones) do zone = z end
    -- sensors are stationary during animation
    local hitWrites, zoneWrites = #hitA._writes(), #zone.canvas._writes()
    local y = cardCanvas.frame().y + 36
    hs._sendMouseMove(50, y); hs._advance(0.1)
    t.eq(#zone.canvas._writes(), zoneWrites, "edge zone never moves with the cards")
    t.eq(#hitA._writes() <= hitWrites + 1, true, "a card sensor only changes on a state change, never per animation frame")
    local hw = #hitA._writes()
    H.settle(hs)
    t.eq(#hitA._writes(), hw, "no sensor movement while the card animates")

    -- idempotent handlers: duplicate / stray events do not retarget
    local started = 0
    local orig = cm.animator.animate
    cm.animator.animate = function(self, ...) started = started + 1; return orig(self, ...) end
    hs._sendMouseMove(20, y); H.settle(hs)
    local afterEnter = started
    t.eq(H.canvasOf(Tuck, a).frame().w, 220)
    hitA._fireMouse("mouseEnter"); hitA._fireMouse("mouseEnter"); H.settle(hs)
    t.eq(started, afterEnter, "duplicate mouseEnter does nothing")
    cm.hitCanvases[Tuck.store:getByWindowID(b.id()).tuckID]._fireMouse("mouseExit")
    t.eq(started, afterEnter, "mouseExit for a card that is not hovered does nothing")
    cm.animator.animate = orig

    -- clicks outside every sensor pass through to the app below
    hs._sendMouseMove(700, 400)
    t.isFalse(hs._click(700, 400), "a click far from the shelf is not captured")
    Tuck:stop()
  end

  -- ===== H. Space change resets stale pointer state (watcher exists only with tucks) =====
  do
    local hs, Tuck = H.boot()
    local a = H.newWin(hs, "Alpha", { title = "A" })
    H.tuck(hs, a, "left"); H.settle(hs)
    local y = H.canvasOf(Tuck, a).frame().y + 36
    hs._sendMouseMove(50, y); H.settle(hs)
    hs._sendMouseMove(20, y); H.settle(hs)
    t.eq(H.canvasOf(Tuck, a).frame().w, 220)
    local watcher
    for _, w in ipairs(hs._spaceWatchers) do if w.running then watcher = w end end
    t.isTrue(watcher ~= nil)
    watcher.fn(2) -- the user switched Space; the exit event never arrived
    H.settle(hs)
    local f = H.canvasOf(Tuck, a).frame()
    t.eq(f.x + f.w, 8, "card parked again")
    t.isNil(Tuck.cardManager.hoveredID)
    t.eq(Tuck.store:count(), 1, "records untouched")
    Tuck:stop()
  end

  -- ===== I. unrelated windows are never touched =====
  do
    local hs, Tuck = H.boot()
    local frames = {}
    local wins = {}
    for i, app in ipairs({ "Safari", "Safari", "Safari", "Mail", "Notes" }) do
      wins[i] = H.newWin(hs, app, { title = "W" .. i, frame = { x = i * 40, y = i * 30, w = 500 + i, h = 400 + i } })
      frames[i] = { x = i * 40, y = i * 30, w = 500 + i, h = 400 + i }
    end
    hs._userFocus(wins[4]); hs._userFocus(wins[1]); hs._userFocus(wins[2]) -- B(4)->A(1)->current(2)
    local function sameFrame(i)
      local f = wins[i].frame()
      return f.x == frames[i].x and f.y == frames[i].y and f.w == frames[i].w and f.h == frames[i].h
    end
    hs._frameWrites = {}
    local focusBefore = #hs._focusLog
    H.shortcut(hs); H.arrow(hs, "left")           -- tuck Safari W2
    t.eq(#hs._frameWrites, 0, "tucking writes no window frame at all")
    t.eq(hs._focusedWindow.id(), wins[1].id(), "exact previous window (same app) regains focus")
    t.eq(#hs._focusLog, focusBefore + 1, "exactly one focus call")
    for _, a in ipairs(hs._activateLog) do t.isFalse(a.all, "no app-wide activate") end
    for i = 1, 5 do t.isTrue(sameFrame(i), "window " .. i .. " frame unchanged by tucking") end
    t.isTrue(wins[3].isVisible() and wins[4].isVisible() and wins[5].isVisible(), "siblings and others stay visible")

    -- rapid focus changes, then tuck another: still the exact previous one
    hs._userFocus(wins[5]); hs._userFocus(wins[3]); hs._userFocus(wins[4]); hs._userFocus(wins[5])
    H.shortcut(hs); H.arrow(hs, "right")           -- tuck Notes W5
    t.eq(hs._focusedWindow.id(), wins[4].id(), "rapid focus changes: previous = Mail W4")
    t.eq(#hs._frameWrites, 0)

    -- restore writes a frame to exactly one window: the restored one
    H.click(Tuck, wins[2])
    t.eq(#hs._frameWrites, 1)
    t.eq(hs._frameWrites[1], wins[2].id(), "only the restored window receives a frame")
    for _, i in ipairs({ 1, 3, 4 }) do t.isTrue(sameFrame(i), "window " .. i .. " untouched by restore") end

    -- a record whose window now belongs to another process never gets a frame
    local rec = Tuck.store:getByWindowID(wins[5].id())
    rec.pid = rec.pid + 999
    hs._frameWrites = {}
    H.click(Tuck, wins[5])
    t.eq(#hs._frameWrites, 0, "identity mismatch: no frame written")
    Tuck:stop()
  end

  -- ===== J. persisted tucks at startup: efficient, lazy =====
  do
    local hs, Tuck, dir = H.boot()
    local a = H.newWin(hs, "Safari", { title = "A" })
    H.tuck(hs, a, "left")
    hs._fireAllTimers()
    hs._simulateReload()
    hs._enumerations, hs._filtersCreated = 0, 0
    local _, T2 = H.boot({ hs = hs, dir = dir })
    t.eq(hs._enumerations or 0, 0, "restoring tucks enumerates no windows via orderedWindows")
    t.eq(hs._filtersCreated, 1, "one window filter, because a tuck exists")
    t.eq(H.resources(hs).repeatingTimers, 0)
    T2:stop()
    -- a state file with only stale records leaves the Spoon idle
    hs._simulateReload()
    a.unminimize(); a.application().unhide()
    local _, T3 = H.boot({ hs = hs, dir = dir })
    expectIdle(H.resources(hs), "stale-only state file")
    T3:stop()
  end

  t.report("lifecycle_spec")
  return #t.failures == 0
end

return run
