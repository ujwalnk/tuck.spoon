--- Centralized frame animator.
--
-- hs.canvas has no documented native frame tween, so smooth motion has to
-- be driven from Lua. Design (as opposed to one fixed-step timer per
-- card):
--
--   * ONE shared ticker for every in-flight animation. It is started
--     lazily when the first animation begins and STOPPED as soon as none
--     remain, so an idle Spoon runs no timer at all.
--   * Progress is computed from real elapsed time
--     (hs.timer.secondsSinceEpoch), never from a step counter, so timer
--     jitter or a slow frame cannot cause stepping/stretching: a late tick
--     simply lands further along the curve. Progress is clamped and
--     therefore monotonic.
--   * Starting an animation for a key that is already animating cancels
--     the old one and continues from the canvas' CURRENT on-screen frame
--     (no popping back to the old start), which keeps rapid in/out and
--     card-to-card hover changes continuous.
--   * Each animation is an object identified by identity; a cancelled or
--     replaced animation can never write a frame again.
--   * The final tick assigns exactly `to`, so cards land on target.
--
-- Easing curves are pure functions and exposed for tests.

local Animator = {}
Animator.__index = Animator

local TICK_INTERVAL = 1 / 60

local easings = {
  linear = function(t)
    return t
  end,
  easeOutCubic = function(t)
    local u = 1 - t
    return 1 - u * u * u
  end,
  easeInOutCubic = function(t)
    if t < 0.5 then
      return 4 * t * t * t
    end
    local u = -2 * t + 2
    return 1 - (u * u * u) / 2
  end,
}
Animator.easings = easings

function Animator.new(hsRef, logger)
  local self = setmetatable({}, Animator)
  self.hs = hsRef
  self.logger = logger
  self.animations = {} -- key -> animation record
  self.ticker = nil
  return self
end

local function sameFrame(a, b)
  return a and b and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
end

local function lerpFrame(from, to, e)
  return {
    x = from.x + (to.x - from.x) * e,
    y = from.y + (to.y - from.y) * e,
    w = from.w + (to.w - from.w) * e,
    h = from.h + (to.h - from.h) * e,
  }
end

function Animator:_now()
  return self.hs.timer.secondsSinceEpoch()
end

function Animator:_ensureTicker()
  if self.ticker then
    return
  end
  self.ticker = self.hs.timer.doEvery(TICK_INTERVAL, function()
    self:_tick()
  end)
end

function Animator:_stopTickerIfIdle()
  if self.ticker and next(self.animations) == nil then
    self.ticker:stop()
    self.ticker = nil
  end
end

function Animator:_tick()
  local now = self:_now()
  -- Snapshot the keys: completion callbacks may start/cancel animations.
  local keys = {}
  for key in pairs(self.animations) do
    keys[#keys + 1] = key
  end
  for _, key in ipairs(keys) do
    local anim = self.animations[key]
    if anim then
      local t = (now - anim.start) / anim.duration
      if t >= 1 then
        self.animations[key] = nil
        local ok = pcall(function()
          anim.canvas:frame(anim.to) -- exact landing
        end)
        if not ok and self.logger then
          self.logger.d("Tuck: animator dropped a frame write for a dead canvas")
        end
        if anim.onComplete then
          pcall(anim.onComplete)
        end
      else
        if t < 0 then
          t = 0
        end
        local ok = pcall(function()
          anim.canvas:frame(lerpFrame(anim.from, anim.to, anim.easing(t)))
        end)
        if not ok then
          self.animations[key] = nil -- canvas is gone; drop it
        end
      end
    end
  end
  self:_stopTickerIfIdle()
end

--- Animate `canvas` (identified by `key`) to `toFrame`.
-- duration <= 0 sets the frame immediately. Returns nothing.
function Animator:animate(key, canvas, toFrame, duration, easingName, onComplete)
  local existing = self.animations[key]
  if existing and existing.canvas == canvas and sameFrame(existing.to, toFrame) then
    return -- already heading exactly there
  end
  self.animations[key] = nil

  local ok, current = pcall(function()
    return canvas:frame()
  end)
  if not ok or not current then
    return
  end

  if not duration or duration <= 0 or sameFrame(current, toFrame) then
    pcall(function()
      canvas:frame(toFrame)
    end)
    self:_stopTickerIfIdle()
    if onComplete then
      pcall(onComplete)
    end
    return
  end

  self.animations[key] = {
    canvas = canvas,
    from = { x = current.x, y = current.y, w = current.w, h = current.h },
    to = { x = toFrame.x, y = toFrame.y, w = toFrame.w, h = toFrame.h },
    start = self:_now(),
    duration = duration,
    easing = easings[easingName] or easings.easeOutCubic,
    onComplete = onComplete,
  }
  self:_ensureTicker()
end

--- Set a frame immediately and cancel any animation for `key`.
function Animator:jump(key, canvas, frame)
  self.animations[key] = nil
  pcall(function()
    canvas:frame(frame)
  end)
  self:_stopTickerIfIdle()
end

--- Cancel `key`'s animation without touching the canvas (idempotent).
function Animator:cancel(key)
  self.animations[key] = nil
  self:_stopTickerIfIdle()
end

function Animator:isAnimating(key)
  return self.animations[key] ~= nil
end

function Animator:activeCount()
  local n = 0
  for _ in pairs(self.animations) do
    n = n + 1
  end
  return n
end

--- Cancel everything and release the ticker (idempotent).
function Animator:stopAll()
  self.animations = {}
  if self.ticker then
    self.ticker:stop()
    self.ticker = nil
  end
end

return Animator
