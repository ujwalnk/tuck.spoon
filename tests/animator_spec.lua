local t = require("tests.testkit")

local function fresh()
  package.loaded["tests.mock_hs"] = nil
  package.loaded["card.animator"] = nil
  local hs = require("tests.mock_hs")
  local Animator = require("card.animator")
  local canvas = hs.canvas.new({ x = 0, y = 0, w = 100, h = 100 })
  return hs, Animator.new(hs), canvas, Animator
end

local function run()
  t.reset()

  -- exact landing, monotonic progress, ticker released
  do
    local hs, an, c = fresh()
    an:animate("k", c, { x = 100, y = 40, w = 200, h = 160 }, 0.2, "easeOutCubic")
    t.eq(hs._activeRepeating(), 1, "one shared ticker")
    hs._advance(0.5)
    local f = c.frame()
    t.eq(f.x, 100); t.eq(f.y, 40); t.eq(f.w, 200); t.eq(f.h, 160)
    local prev = -math.huge
    for _, w in ipairs(c._writes()) do
      t.isTrue(w.x >= prev - 1e-9, "x never goes backwards")
      prev = w.x
    end
    t.eq(hs._activeRepeating(), 0, "ticker stopped when idle")
    t.eq(an:activeCount(), 0)
  end

  -- time-based: a late/slow tick lands further along the curve (no stepping)
  do
    local hs, an, c = fresh()
    an:animate("k", c, { x = 100, y = 0, w = 100, h = 100 }, 1.0, "linear")
    hs._now = hs._now + 0.5
    hs._pendingTimers[#hs._pendingTimers].fn()
    t.almostEq(c.frame().x, 50, 1e-6, "progress follows elapsed time, not tick count")
    hs._now = hs._now + 0.6
    hs._pendingTimers[#hs._pendingTimers].fn()
    t.eq(c.frame().x, 100, "lands exactly even after a very late tick")
  end

  -- replacement continues from the current frame; the old target can never overwrite
  do
    local hs, an, c = fresh()
    an:animate("k", c, { x = 200, y = 0, w = 100, h = 100 }, 0.3, "linear")
    hs._advance(0.15)
    local mid = c.frame().x
    t.isTrue(mid > 0 and mid < 200)
    an:animate("k", c, { x = -50, y = 0, w = 100, h = 100 }, 0.3, "linear")
    local writesAtSwitch = #c._writes()
    t.eq(an:activeCount(), 1, "replaced, not stacked")
    hs._advance(0.1)
    local w = c._writes()
    for i = writesAtSwitch + 1, #w do
      t.isTrue(w[i].x <= mid + 1e-6, "new animation departs from the current position, never jumps to the old target")
    end
    hs._advance(1)
    t.eq(c.frame().x, -50, "final target of the newest animation wins")
    local n = #c._writes()
    hs._advance(1)
    t.eq(#c._writes(), n, "nothing writes after completion")
  end

  -- identical target does not restart; zero duration jumps; cancel/jump/stopAll
  do
    local hs, an, c = fresh()
    an:animate("k", c, { x = 100, y = 0, w = 100, h = 100 }, 0.3, "linear")
    hs._advance(0.1)
    local n = #c._writes()
    an:animate("k", c, { x = 100, y = 0, w = 100, h = 100 }, 0.3, "linear")
    hs._advance(0.017)
    t.eq(an:activeCount(), 1, "same target keeps the running animation")
    an:animate("k", c, { x = 5, y = 0, w = 100, h = 100 }, 0, "linear")
    t.eq(c.frame().x, 5, "duration 0 jumps")
    t.eq(an:activeCount(), 0)
    t.eq(hs._activeRepeating(), 0)

    an:animate("a", c, { x = 300, y = 0, w = 100, h = 100 }, 0.3)
    an:animate("b", c, { x = 400, y = 0, w = 100, h = 100 }, 0.3)
    an:cancel("a")
    t.eq(an:activeCount(), 1)
    an:stopAll()
    t.eq(an:activeCount(), 0)
    t.eq(hs._activeRepeating(), 0, "stopAll releases the ticker")
    an:cancel("missing") -- idempotent
  end

  -- a dead canvas is dropped, not retried forever
  do
    local hs, an = fresh()
    local dead = { frame = function(_, f) if f then error("canvas gone") end return { x = 0, y = 0, w = 1, h = 1 } end }
    an:animate("d", dead, { x = 50, y = 0, w = 1, h = 1 }, 0.2)
    hs._advance(0.05)
    t.eq(an:activeCount(), 0, "animation on a dead canvas is discarded")
    t.eq(hs._activeRepeating(), 0)
  end

  -- easing curves: endpoints and monotonic
  do
    local _, _, _, Animator = fresh()
    for name, fn in pairs(Animator.easings) do
      t.almostEq(fn(0), 0, 1e-9, name .. " starts at 0")
      t.almostEq(fn(1), 1, 1e-9, name .. " ends at 1")
      local prev = 0
      for i = 1, 100 do
        local v = fn(i / 100)
        t.isTrue(v >= prev - 1e-12, name .. " monotonic")
        prev = v
      end
    end
  end

  t.report("animator_spec")
  return #t.failures == 0
end

return run
