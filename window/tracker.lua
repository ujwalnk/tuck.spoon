--- Window lifecycle tracker.
--
-- A sensor, not the business-logic owner (per spec). Wraps a single
-- `hs.window.filter` instance and reports lifecycle events -- minimized,
-- unminimized, destroyed, and (for reconciliation purposes) moved and
-- title-changed -- to callbacks supplied by the owner (window/manager.lua).
-- This module never decides what those events MEAN; it only forwards
-- them, defensively (any handler error is caught so one misbehaving
-- callback, or one application's unusual Accessibility behavior, can
-- never crash the whole Spoon).
--
-- We track `hs.window.filter.new(true)`: matches every standard
-- application window regardless of which app owns it (rather than one
-- window filter per app), so multiple windows from the same application
-- are all still tracked individually and consistently, per spec's
-- window-identity requirements. `true` is the documented idiom for "do
-- not restrict by any per-application allow/reject rules."

local Tracker = {}
Tracker.__index = Tracker

function Tracker.new(hsRef, logger)
  local self = setmetatable({}, Tracker)
  self.hs = hsRef
  self.logger = logger
  self.wf = nil

  -- Callbacks, each `function(window, appName)`. Set by the owner
  -- (window/manager.lua) before calling :start().
  self.onMinimized = nil
  self.onUnminimized = nil
  self.onDestroyed = nil
  self.onMoved = nil
  self.onTitleChanged = nil

  return self
end

local function safeCall(logger, label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and logger then
    logger.e("Tuck: error in tracker callback (" .. label .. "): " .. tostring(err))
  end
end

--- Start tracking. Idempotent: calling twice tears down and recreates
-- the underlying window filter rather than accumulating a second one.
function Tracker:start()
  self:stop()

  local hs = self.hs
  local this = self

  local ok, wf = pcall(function()
    return hs.window.filter.new(true)
  end)
  if not ok or not wf then
    if self.logger then
      self.logger.e("Tuck: failed to create hs.window.filter: " .. tostring(wf))
    end
    return
  end
  self.wf = wf

  self.wf:subscribe(hs.window.filter.windowMinimized, function(window, appName)
    safeCall(this.logger, "windowMinimized", function()
      if this.onMinimized then
        this.onMinimized(window, appName)
      end
    end)
  end)

  self.wf:subscribe(hs.window.filter.windowUnminimized, function(window, appName)
    safeCall(this.logger, "windowUnminimized", function()
      if this.onUnminimized then
        this.onUnminimized(window, appName)
      end
    end)
  end)

  self.wf:subscribe(hs.window.filter.windowDestroyed, function(window, appName)
    safeCall(this.logger, "windowDestroyed", function()
      if this.onDestroyed then
        this.onDestroyed(window, appName)
      end
    end)
  end)

  self.wf:subscribe(hs.window.filter.windowMoved, function(window, appName)
    safeCall(this.logger, "windowMoved", function()
      if this.onMoved then
        this.onMoved(window, appName)
      end
    end)
  end)

  self.wf:subscribe(hs.window.filter.windowTitleChanged, function(window, appName)
    safeCall(this.logger, "windowTitleChanged", function()
      if this.onTitleChanged then
        this.onTitleChanged(window, appName)
      end
    end)
  end)
end

--- Stop tracking and release the window filter. Idempotent.
function Tracker:stop()
  if self.wf then
    local ok, err = pcall(function()
      self.wf:unsubscribeAll()
    end)
    if not ok and self.logger then
      self.logger.d("Tuck: window filter unsubscribeAll raised (tolerated): " .. tostring(err))
    end
    self.wf = nil
  end
end

return Tracker
