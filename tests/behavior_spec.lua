--- Focus ordering (MinimizeToPrevious approach), edge-reveal stability,
-- animation ownership, card visuals, Space/screen search and lifecycle.

local t = require("tests.testkit")
local H = require("tests.harness")
local Renderer = require("card.renderer")

local function withScreenRecording(hs)
  hs.screenRecordingState = function() return true end
end

local function pct(str)
  return tonumber(str:match("^([%d%.%-]+)%%$")) / 100
end

local function iconBadge(elements, icon)
  local found
  for _, e in ipairs(elements) do
    if e.type == "image" and e.image and e.image.bundleID and e.imageAlignment ~= "center" then found = e end
  end
  return found
end

local function run()
  t.reset()

  -- ===== FOCUS: previous window is focused BEFORE the current one is hidden =====
  do
    local hs, Tuck = H.boot()
    local b = H.newWin(hs, "Safari", { title = "B" })
    local a = H.newWin(hs, "Safari", { title = "A" })
    local c = H.newWin(hs, "Safari", { title = "C" })
    hs._userFocus(b); hs._userFocus(a)
    local focusCountAtMinimize
    local origMin = a.minimize
    a.minimize = function()
      focusCountAtMinimize = #hs._focusLog
      origMin()
    end
    local before = #hs._focusLog
    H.shortcut(hs); H.arrow(hs, "left")
    t.eq(focusCountAtMinimize, before + 1, "exactly one focus call happened before the hide")
    t.eq(hs._focusLog[before + 1], b.id(), "…and it was the exact previous window")
    t.eq(hs._focusLog[#hs._focusLog], b.id(), "nothing refocused afterwards: macOS never gets to choose")
    t.eq(hs._focusedWindow.id(), b.id())
    t.isTrue(c.isVisible(), "third same-app window untouched and not selected")
    -- history: C focused, then A (already tucked) must not be offered
    hs._userFocus(c)
    H.tuck(hs, c, "right")
    t.eq(hs._focusedWindow.id(), b.id(), "after tucking C the previous valid window is B (A is tucked)")
    Tuck:stop()
  end

  -- ===== FOCUS: no history -> next window behind (never same-app sibling) =====
  do
    local hs, Tuck = H.boot()
    local sibling = H.newWin(hs, "Safari", { title = "Sibling" })
    local behind = H.newWin(hs, "Mail", { title = "Behind" })
    local target = H.newWin(hs, "Safari", { title = "Target" })
    hs._zOrder = { target, sibling, behind }
    hs._focusedWindow = target -- focused without ever generating history
    Tuck.focusHistory:clear()
    H.shortcut(hs); H.arrow(hs, "left")
    t.eq(hs._focusedWindow.id(), behind.id(), "front-to-back fallback skips the same-app sibling")
    t.isTrue(sibling.isVisible())
    Tuck:stop()
  end

  -- ===== FOCUS: previous window on an inactive Space is not yanked to =====
  do
    local hs, Tuck = H.boot()
    local other = H.newWin(hs, "Mail", { title = "OtherSpace", spaces = { 7 } })
    local cur = H.newWin(hs, "Safari", { title = "Cur" })
    hs._userFocus(other); hs._userFocus(cur)
    local before = #hs._focusLog
    H.shortcut(hs); H.arrow(hs, "left")
    t.eq(#hs._focusLog, before, "window on another Space is never focused")
    Tuck:stop()
  end

  -- ===== FOCUS: failed hide puts focus back and creates no state =====
  do
    local hs, Tuck = H.boot()
    local prev = H.newWin(hs, "Mail", { title = "Prev" })
    local cur = H.newWin(hs, "Safari", { title = "Cur" })
    local other = H.newWin(hs, "Safari", { title = "Other" })
    hs._userFocus(prev); hs._userFocus(cur)
    cur.minimize = function() error("AX failure") end
    H.shortcut(hs); H.arrow(hs, "left")
    t.eq(#Tuck.store:allWindows(), 0, "no record for a window that was not hidden")
    t.eq(hs._focusedWindow.id(), cur.id(), "focus returned to the window that failed to tuck")
    Tuck:stop()
  end

  -- ===== EDGE REVEAL: one animation, stable while the pointer rests =====
  do
    local hs, Tuck = H.boot()
    local w = H.newWin(hs, "Alpha", { title = "A" })
    H.tuck(hs, w, "left"); H.settle(hs)
    local cm = Tuck.cardManager
    local started = 0
    local origAnimate = cm.animator.animate
    cm.animator.animate = function(self, ...)
      started = started + 1
      return origAnimate(self, ...)
    end
    local canvas = H.canvasOf(Tuck, w)
    local y = canvas.frame().y + 36
    local writesBefore = #canvas._writes()

    hs._sendMouseMove(50, y)            -- enter the trigger strip (beside the revealed card)
    local afterEntry = started
    t.isTrue(afterEntry >= 1 and afterEntry <= 1, "entering the edge starts exactly one animation")
    -- the pointer now rests / jitters by a pixel while the card slides under it
    for i = 1, 60 do
      hs._advance(1 / 60)
      hs._sendMouseMove(50 + (i % 2), y)
    end
    t.eq(started, afterEntry, "no animation restarted while the pointer stayed at the edge")
    local f = canvas.frame()
    t.eq(f.x + f.w, 40, "settled at the revealed depth")
    -- monotonic travel: reveal never oscillates
    local writes = canvas._writes()
    local last = -math.huge
    for i = writesBefore + 1, #writes do
      local right = writes[i].x + writes[i].w
      t.isTrue(right >= last - 1e-6, "reveal progress is monotonic")
      last = right
    end
    t.eq(H.countKeys(cm.animator.animations), 0, "no animation left running")
    t.eq(hs._activeRepeating(), 0, "ticker stopped")

    -- leaving: one smooth return after the grace delay
    started = 0
    hs._sendMouseMove(700, 400)
    t.eq(started, 0, "nothing moves before the grace delay")
    hs._fireAllTimers(); H.settle(hs)
    t.eq(started, 1, "exactly one return animation")
    t.eq(canvas.frame().x + canvas.frame().w, 8, "parked again")
    Tuck:stop()
  end

  -- ===== EDGE REVEAL: extreme edge pixels / expansion never feed back =====
  do
    local hs, Tuck = H.boot()
    local a = H.newWin(hs, "Alpha", { title = "A" }); local b = H.newWin(hs, "Beta", { title = "B" })
    H.tuck(hs, a, "left"); H.tuck(hs, b, "left"); H.settle(hs)
    local ca, cb = H.canvasOf(Tuck, a), H.canvasOf(Tuck, b)
    local cm = Tuck.cardManager
    local transitions = 0
    local lastHover
    local function track()
      if cm.hoveredID ~= lastHover then transitions = transitions + 1; lastHover = cm.hoveredID end
    end
    local y = ca.frame().y + 36
    hs._sendMouseMove(0, y); track()  -- the very first pixel of the screen
    t.isTrue(cm.hoveredID ~= nil, "pointer on the extreme edge pixel hovers the card")
    for i = 1, 90 do
      hs._advance(1 / 60)
      hs._sendMouseMove(0, y); track()
    end
    t.eq(transitions, 1, "hover state never flipped while the card expanded under a still pointer")
    t.eq(ca.frame().w, 220, "card fully expanded")
    t.isTrue(ca.frame().x >= 0)
    -- hysteresis: drifting inside the expanded frame keeps it expanded
    hs._sendMouseMove(200, y + 60); track()
    t.eq(transitions, 1, "inside the expanded frame (beyond the resting card) keeps the hover")
    -- moving to the second card: exactly one hand-over
    hs._sendMouseMove(700, 400); track()
    hs._advance(0.5)
    hs._sendMouseMove(20, cb.frame().y + 36); track()
    t.eq(cm.hoveredID, Tuck.store:getByWindowID(b.id()).tuckID)
    hs._advance(0.6)
    t.eq(ca.frame().w, 72, "previous card collapsed"); t.eq(cb.frame().w, 220, "new card expanded")
    t.eq(H.countKeys(cm.hovered), 1, "at most one hovered card")
    Tuck:stop()
  end

  -- ===== ANIMATION OWNERSHIP: superseded targets, cancelled/destroyed cards =====
  do
    local hs, Tuck = H.boot()
    local a = H.newWin(hs, "Alpha", { title = "A" }); local b = H.newWin(hs, "Beta", { title = "B" })
    H.tuck(hs, a, "left"); H.tuck(hs, b, "left"); H.settle(hs)
    local ca = H.canvasOf(Tuck, a)
    local y = ca.frame().y + 36
    hs._sendMouseMove(20, y); hs._advance(0.05) -- mid-flight
    t.eq(Tuck.cardManager.animator:activeCount() >= 1, true)
    hs._sendMouseMove(700, 400); hs._advance(0.03)
    -- newest target (collapse) must win; old expand must never write again
    hs._fireAllTimers(); H.settle(hs)
    t.eq(ca.frame().w, 72, "newest target wins")
    t.eq(ca.frame().x + ca.frame().w, 8)
    -- destroy a card while animating
    hs._sendMouseMove(20, y); hs._advance(0.04)
    local rec = Tuck.store:getByWindowID(a.id())
    local writesAtDestroy
    Tuck.windowManager:forget(rec)
    writesAtDestroy = #ca._writes()
    hs._advance(1)
    t.eq(#ca._writes(), writesAtDestroy, "no write after the card was destroyed")
    t.isNil(Tuck.cardManager.animator.animations[rec.tuckID], "animation cleaned up with the card")
    t.isTrue(ca._isDeleted())
    hs._sendMouseMove(700, 400); hs._fireAllTimers(); H.settle(hs)
    t.eq(hs._activeRepeating(), 0, "no timer leaks")
    Tuck:stop()
  end

  -- ===== SEARCH expansion stays stable and shares the expanded state =====
  do
    local hs, Tuck = H.boot()
    local a = H.newWin(hs, "Sa", { title = "A" }); local b = H.newWin(hs, "Sb", { title = "B" })
    local o = H.newWin(hs, "Other", { title = "O" })
    H.tuck(hs, a, "left"); H.tuck(hs, b, "left"); H.tuck(hs, o, "left"); H.settle(hs)
    hs._focusedWindow = H.newWin(hs, "Finder")
    H.shortcut(hs); H.letter(hs, "s")
    local started = 0
    local orig = Tuck.cardManager.animator.animate
    Tuck.cardManager.animator.animate = function(self, ...) started = started + 1; return orig(self, ...) end
    H.settle(hs)
    t.eq(H.canvasOf(Tuck, a).frame().w, 220); t.eq(H.canvasOf(Tuck, b).frame().w, 220)
    t.eq(H.canvasOf(Tuck, o).frame().w, 72)
    for _ = 1, 30 do hs._advance(1 / 60) end
    t.eq(started, 0, "an unchanged search match set triggers no further animation")
    H.esc(hs); H.settle(hs)
    t.eq(H.canvasOf(Tuck, a).frame().w, 72)
    Tuck:stop()
  end

  -- ===== CARD VISUALS: inward-facing icon =====
  do
    local cfg = require("config.defaults").defaults.card
    local icon = { bundleID = "x" }
    local thumb = { thumb = true }
    local function badge(edge)
      local els = Renderer.buildElements({ appName = "App", edge = edge, bundleID = "x" }, { w = 72, h = 72 }, cfg, icon, thumb)
      return iconBadge(els), els
    end
    local left = badge("left"); local right = badge("right"); local top = badge("top"); local bottom = badge("bottom")
    t.eq(left.imageAlignment, "bottomRight", "left rail: icon bottom-right")
    t.eq(right.imageAlignment, "bottomLeft", "right rail: icon bottom-left")
    t.eq(top.imageAlignment, "bottom", "top rail: icon toward the bottom (inward)")
    t.eq(bottom.imageAlignment, "top", "bottom rail: icon toward the top (inward)")
    t.isTrue(pct(left.frame.x) > 0.5, "left-rail badge sits in the right half")
    t.isTrue(pct(right.frame.x) < 0.5, "right-rail badge sits in the left half")
    t.isTrue(pct(top.frame.y) + pct(top.frame.h) / 2 > 0.5, "top-rail badge centred in the lower half")
    t.isTrue(pct(bottom.frame.y) + pct(bottom.frame.h) / 2 < 0.5, "bottom-rail badge centred in the upper half")
    for _, bd in ipairs({ left, right, top, bottom }) do
      local x, y, w, h = pct(bd.frame.x), pct(bd.frame.y), pct(bd.frame.w), pct(bd.frame.h)
      t.isTrue(x >= 0 and y >= 0 and x + w <= 1 + 1e-9 and y + h <= 1 + 1e-9, "badge fully inside the card")
    end
    -- only the icon moves: thumbnail / labels identical across edges
    local _, le = badge("left"); local _, re = badge("right")
    t.eq(#le, #re)
    for i = 1, #le do
      if le[i].image ~= icon then
        t.eq(le[i].frame and le[i].frame.x, re[i].frame and re[i].frame.x, "non-icon element " .. i .. " unchanged")
      end
    end
    local an = Renderer.inwardAnchor
    t.eq(an("left").h, "right"); t.eq(an("right").h, "left"); t.eq(an("top").v, "bottom"); t.eq(an("bottom").v, "top")

    -- badges are percentage-based, so parked/revealed/expanded keep their place
    t.isTrue(type(left.frame.x) == "string" and left.frame.x:find("%%") ~= nil, "percent layout scales with the card")

    -- parked card: the badge is in the part of the card that stays on screen
    local hs, Tuck = H.boot()
    local w = H.newWin(hs, "Safari", { title = "S" })
    H.tuck(hs, w, "left"); H.settle(hs)
    local f = H.frameOf(Tuck, w)
    local visibleFrac = (f.x + f.w) / f.w
    t.isTrue(visibleFrac < 0.2, "only a thin sliver of a parked left card is visible")
    local inward = pct(left.frame.x) + pct(left.frame.w)
    t.isTrue(inward > 0.9, "badge hugs the inward edge, the side that faces the screen")
    Tuck:stop()
  end

  -- ===== CARD VISUALS: rounded thumbnail =====
  do
    local hs, Tuck = H.boot({ prepare = withScreenRecording })
    local w = H.newWin(hs, "Safari", { title = "S" })
    H.tuck(hs, w, "left")
    t.eq(#hs._bakeLog, 1, "snapshot baked once, off-screen")
    local bake = hs._bakeLog[1]
    local clip, img, reset = bake.elements[1], bake.elements[2], bake.elements[3]
    t.eq(clip.action, "clip", "rounded clip path"); t.eq(reset.type, "resetClip")
    t.eq(img.type, "image")
    local cfg = Tuck.config.card
    local displayW = Renderer.referenceDisplayWidth(cfg, bake.size.w / bake.size.h)
    local expected = Renderer.thumbnailRadius(cfg) * (bake.size.w / displayW)
    t.almostEq(clip.roundedRectRadii.xRadius, expected, 1e-6, "radius derives from the card's cornerRadius")
    t.eq(clip.roundedRectRadii.xRadius, clip.roundedRectRadii.yRadius, "same radius on every corner")
    t.isTrue(bake.size.w <= 2 * cfg.expandedWidth + 1, "oversized snapshots are downsized")
    t.isTrue(clip.frame.w == bake.size.w and clip.frame.h == bake.size.h, "clip covers the whole image")

    -- configured radius changes the thumbnail radius
    local hs2, T2 = H.boot({ prepare = withScreenRecording, configure = { card = { cornerRadius = 24 } } })
    local w2 = H.newWin(hs2, "Safari", { title = "S" })
    H.tuck(hs2, w2, "left")
    local r2 = hs2._bakeLog[1].elements[1].roundedRectRadii.xRadius
    t.isTrue(r2 > clip.roundedRectRadii.xRadius, "larger card radius -> larger thumbnail radius")
    T2:stop()
    _G.hs = hs -- the second boot replaced the global mock; return to the first

    -- the card draws the pre-rounded image; hover expansion reuses it without re-rendering
    local rec = Tuck.store:getByWindowID(w.id())
    local els = Tuck.cardManager.canvases[rec.tuckID]._elements()
    local thumbEl
    for _, e in ipairs(els) do if e.image and e.image.baked then thumbEl = e end end
    t.isTrue(thumbEl ~= nil, "card shows the rounded image")
    t.eq(thumbEl.frame.x:find("%%") ~= nil, true)
    H.settle(hs)
    hs._sendMouseMove(20, H.canvasOf(Tuck, w).frame().y + 36); H.settle(hs)
    t.eq(Tuck.cardManager.canvases[rec.tuckID]._elements(), els, "no re-render while expanding: corners stay clean")
    t.eq(#hs._bakeLog, 1, "no re-baking during animation")
    -- bake failure never prevents tucking
    hs.canvas.new = (function(orig) return function(f)
      local c = orig(f); c.imageFromCanvas = function() error("boom") end; return c end end)(hs.canvas.new)
    local w3 = H.newWin(hs, "Mail", { title = "M" })
    H.tuck(hs, w3, "left")
    t.isTrue(Tuck.store:getByWindowID(w3.id()) ~= nil, "thumbnail failure does not break tucking")
    Tuck:stop()
  end

  -- ===== SPACE / SCREEN: search scopes, independent shelves =====
  do
    local prep = function(h) h._addScreen("EXT", { x = -1920, y = 0, w = 1920, h = 1080 }) end
    local hs, Tuck = H.boot({ prepare = prep, configure = { search = { scope = "space" } } })
    local ext = hs._screens[2]
    local a = H.newWin(hs, "Safari", { title = "A" }); local b = H.newWin(hs, "Safari", { title = "B", screen = ext })
    H.tuck(hs, a, "left"); H.tuck(hs, b, "left")
    local fa = H.frameOf(Tuck, a); local fb = H.frameOf(Tuck, b)
    local _, T2 = H.reload(hs, Tuck, { configure = { search = { scope = "space" } } })
    local fa2, fb2 = H.frameOf(T2, a), H.frameOf(T2, b)
    t.eq(fa2.x, fa.x); t.eq(fb2.x, fb.x, "physical placement unchanged by restart or search scope")
    hs._focusedWindow = H.newWin(hs, "Finder")
    H.shortcut(hs); H.letter(hs, "s")
    t.eq(H.countKeys(T2.cardManager.searchMatched), 2, "space scope: both screens match after a restart")
    H.esc(hs)
    T2:stop()
  end

  -- ===== LIFECYCLE: internal restore does no duplicate cleanup =====
  do
    local hs, Tuck, dir = H.boot()
    local a = H.newWin(hs, "Safari", { title = "A" }); local b = H.newWin(hs, "Safari", { title = "B" })
    H.tuck(hs, a, "left"); H.tuck(hs, b, "left")
    local cleanups = 0
    local orig = Tuck.windowManager._cleanupRecord
    Tuck.windowManager._cleanupRecord = function(self, rec) cleanups = cleanups + 1; return orig(self, rec) end
    H.canvasOf(Tuck, a)._fireMouse("mouseUp")
    t.eq(cleanups, 1, "restore cleans up exactly once even though unminimize fires an event")
    t.eq(#Tuck.store:allWindows(), 1)
    Tuck:stop(); Tuck:stop(); Tuck:start(); Tuck:stop()
    t.eq(H.liveCanvases(hs), 0)
    t.eq(hs._activeRepeating(), 0)
    t.eq(#hs._wfSubscribers, 0)
  end

  t.report("behavior_spec")
  return #t.failures == 0
end

return run
